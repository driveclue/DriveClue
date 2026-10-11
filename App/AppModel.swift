import AppKit
import DriveClueCore
import IOKit.pwr_mgt
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

struct SidebarSelection: Hashable {
    var driveID: String
    var page: DrivePage
}

@MainActor
@Observable
final class AppModel {
    var drives: [DriveSnapshot] = []
    var selection: SidebarSelection?
    var isRefreshing = false
    var histories: [String: [HistorySample]] = [:]
    var events: [String: [DriveEvent]] = [:]
    var indicatorQuery = ""
    var typeFilter: TypeFilter = .any
    var statusFilter: StatusFilter = .any
    var indicatorSort: IndicatorSort = .id
    var sortAscending = true
    var selectedIndicatorID: Int?
    var alertText: String?
    var sleepAssertionHeld = false
    var usage: UsageScanState?
    var benchmark: DiskBenchmarkState?
    var ioErrorReadings: [String: (count: Int, checkedAt: Date)] = [:]
    var ioErrorUnavailableDrives: Set<String> = []

    let history = HistoryStore()
    private var timer: Timer?
    private var previousStatus: [String: IndicatorStatus] = [:]
    private var previousIndicatorStatuses: [String: [Int: IndicatorStatus]] = [:]
    private var notificationsAuthorized = false
    private var pendingIOErrorRefresh = false
    private var selfTestWasRunning: Set<String> = []
    private var sleepAssertion: IOPMAssertionID = 0
    private var usageTask: Task<Void, Never>?
    private var usageGeneration = 0
    private var benchmarkTask: Task<Void, Never>?
    private var benchmarkGeneration = 0

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var selectedDrive: DriveSnapshot? {
        drives.first { $0.id == selection?.driveID }
    }

    func start() async {
        // Clear the login item left by older builds that exposed a preference for it.
        if UserDefaults.standard.data(forKey: "DriveStats.Settings") != nil {
            if SMAppService.mainApp.status == .enabled {
                try? await SMAppService.mainApp.unregister()
            }
            if SMAppService.mainApp.status != .enabled {
                UserDefaults.standard.removeObject(forKey: "DriveStats.Settings")
            }
        }
        // Obtain permission before the initial scan can produce notifications.
        notificationsAuthorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
        scheduleTimer()
        await refresh()
    }

    func refresh(includeIOErrors: Bool = false) async {
        guard !isRefreshing else {
            if includeIOErrors { pendingIOErrorRefresh = true }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if pendingIOErrorRefresh {
                pendingIOErrorRefresh = false
                Task { await self.refresh(includeIOErrors: true) }
            }
        }
        let scanned = await Task.detached(priority: .userInitiated) { [includeIOErrors] in
            DriveReader.scan { name in
                includeIOErrors ? IOErrorCounter.countIfAvailable(bsdName: name) : nil
            }
        }.value
        let stamped = history.applyDeltas(scanned)
        // Compare against the last successful observation before recording this scan.
        react(to: stamped)
        history.record(stamped)
        if includeIOErrors {
            let checkedAt = Date()
            ioErrorUnavailableDrives = Set(stamped.filter { $0.ioErrorCount == nil }.map(\.id))
            for drive in stamped {
                if let count = drive.ioErrorCount {
                    ioErrorReadings[drive.id] = (count, checkedAt)
                }
            }
        }
        // NVMe drives report no lifetime temperature extremes, so fill them from the
        // checks DriveClue has recorded; ATA drives carry the drive's own values.
        drives = stamped.map { drive in
            guard drive.transport == .nvme, let current = drive.temperatureCelsius,
                  drive.temperatureMin == nil || drive.temperatureMax == nil else { return drive }
            var copy = drive
            let range = history.temperatureRange(driveID: drive.id)
            copy.temperatureMin = min(range?.min ?? current, current)
            copy.temperatureMax = max(range?.max ?? current, current)
            return copy
        }
        if selection == nil, let first = stamped.first {
            selection = SidebarSelection(driveID: first.id, page: .dashboard)
        } else if let selection, !stamped.contains(where: { $0.id == selection.driveID }) {
            self.selection = stamped.first.map { SidebarSelection(driveID: $0.id, page: .dashboard) }
        }
        for drive in stamped {
            histories[drive.id] = history.samples(driveID: drive.id)
            events[drive.id] = history.events(driveID: drive.id)
        }
        let busy = stamped.contains { $0.selfTestProgress != nil }
        scheduleTimer(seconds: busy ? 5 : nil)
        if !busy { releaseSleepAssertion() }
    }

    func refreshWithIOErrors() async {
        await refresh(includeIOErrors: true)
    }

    func selectAdjacentDrive(_ offset: Int) {
        guard !drives.isEmpty else { return }
        let index = drives.firstIndex { $0.id == selection?.driveID } ?? 0
        let next = (index + offset + drives.count) % drives.count
        selection = SidebarSelection(driveID: drives[next].id, page: selection?.page ?? .dashboard)
    }

    func selectPage(_ page: DrivePage) {
        guard let driveID = selection?.driveID ?? drives.first?.id else { return }
        selection = SidebarSelection(driveID: driveID, page: page)
    }

    func export(format: ReportFormat) {
        let panel = NSSavePanel()
        switch format {
        case .text:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "DriveClue Report.txt"
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "DriveClue Indicators.csv"
        case .json:
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "DriveClue Report.json"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload: Data
        switch format {
        case .text: payload = Data(ReportBuilder.text(drives: drives).utf8)
        case .csv: payload = Data(ReportBuilder.csv(drives: drives).utf8)
        case .json: payload = ReportBuilder.json(drives: drives)
        }
        guard !payload.isEmpty else {
            alertText = "Couldn’t generate the report. No file was saved."
            return
        }
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            alertText = "Couldn’t save the report: \(error.localizedDescription)"
        }
    }

    func startSelfTest(extended: Bool) async {
        guard let drive = selectedDrive else { return }
        if extended { holdSleepAssertion() }
        let error = await Task.detached { DriveReader.startSelfTest(bsdName: drive.bsdName, extended: extended) }.value
        if let error {
            alertText = error
            releaseSleepAssertion()
        }
        await refresh()
    }

    func abortSelfTest() async {
        guard let drive = selectedDrive else { return }
        let error = await Task.detached { DriveReader.abortSelfTest(bsdName: drive.bsdName) }.value
        alertText = error
        releaseSleepAssertion()
    }

    func startBenchmark(drive: DriveSnapshot, volume: VolumeInfo, testSize: DiskBenchmarkSize, passes: DiskBenchmarkPasses = .four) {
        guard let mount = volume.mountPath, !mount.isEmpty, benchmarkTask == nil else { return }
        let directory: URL
        if let automaticDirectory = DiskBenchmark.defaultDirectory(volumePath: mount) {
            directory = automaticDirectory
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose a benchmark folder"
            panel.message = "Choose a writable folder on \(volume.name) for the temporary test file."
            panel.prompt = "Use folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: mount, isDirectory: true)
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            guard DiskBenchmark.isOnVolume(directory: chosen, volumePath: mount) else {
                alertText = "Choose a folder on \(volume.name) so the benchmark tests the selected drive."
                return
            }
            directory = chosen
        }
        benchmarkGeneration += 1
        let generation = benchmarkGeneration
        benchmark = DiskBenchmarkState(
            driveID: drive.id,
            volumeBSD: volume.bsdName,
            volumeName: volume.name,
            testSize: testSize,
            passes: passes,
            directoryPath: directory.path,
            progress: DiskBenchmarkProgress(phase: .preparing, completedBytes: 0, totalBytes: testSize.rawValue * 2 * UInt64(passes.count ?? 1), totalRounds: passes.count)
        )
        benchmarkTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let model = self else { return }
            let scopedAccess = directory.startAccessingSecurityScopedResource()
            defer { if scopedAccess { directory.stopAccessingSecurityScopedResource() } }
            do {
                let result = try DiskBenchmark.run(
                    volumePath: mount,
                    testSize: testSize.rawValue,
                    directoryPath: directory.path,
                    passes: passes,
                    shouldContinue: { !Task.isCancelled },
                    progress: { progress in
                        Task { @MainActor in
                            guard model.benchmarkGeneration == generation else { return }
                            model.benchmark?.progress = progress
                            if progress.phase == .writing {
                                model.benchmark?.writeSpeed = progress.currentMBps
                            } else if progress.phase == .reading {
                                model.benchmark?.readSpeed = progress.currentMBps
                            } else if progress.phase == .resetting {
                                model.benchmark?.writeSpeed = 0
                                model.benchmark?.readSpeed = 0
                            }
                        }
                    }
                )
                await MainActor.run {
                    guard model.benchmarkGeneration == generation else { return }
                    model.benchmark?.result = result
                    model.benchmark?.writeSpeed = result.writeMBps
                    model.benchmark?.readSpeed = result.readMBps
                    model.benchmark?.isRunning = false
                    model.benchmark?.progress = DiskBenchmarkProgress(
                        phase: .finished,
                        completedBytes: testSize.rawValue * 2 * UInt64(passes.count ?? 1),
                        totalBytes: testSize.rawValue * 2 * UInt64(passes.count ?? 1),
                        currentMBps: result.readMBps,
                        round: result.rounds.count,
                        totalRounds: passes.count
                    )
                    model.benchmarkTask = nil
                }
            } catch {
                await MainActor.run {
                    guard model.benchmarkGeneration == generation else { return }
                    model.benchmark?.isRunning = false
                    model.benchmark?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    model.benchmarkTask = nil
                }
            }
        }
    }

    func cancelBenchmark() {
        guard benchmarkTask != nil else { return }
        benchmarkGeneration += 1
        benchmarkTask?.cancel()
        benchmarkTask = nil
        benchmark?.isRunning = false
        benchmark?.error = DiskBenchmarkError.cancelled.localizedDescription
    }

    func startUsageScan(drive: DriveSnapshot, volume: VolumeInfo) {
        guard let mount = volume.mountPath else { return }
        usageTask?.cancel()
        usageGeneration += 1
        let generation = usageGeneration
        if usage?.driveID == drive.id, usage?.volumeBSD == volume.bsdName {
            usage?.volumePath = mount
            usage?.volumeName = volume.name
            usage?.isScanning = true
            usage?.startedAt = .now
            usage?.scannedFiles = 0
            usage?.scannedFolders = 0
            usage?.currentPath = ""
            usage?.scanPhase = .scanning
            usage?.scanWasCancelled = false
        } else {
            usage = UsageScanState(driveID: drive.id, volumeBSD: volume.bsdName, volumePath: mount, volumeName: volume.name, isScanning: true, startedAt: .now)
        }
        usageTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Bind the model once so the progress sink is not re-capturing a weak var.
            guard let model = self else { return }
            let result = await UsageScanner.scan(
                rootPath: mount,
                volumeName: volume.name,
                progress: { progress in
                    Task { @MainActor in
                        guard model.usageGeneration == generation else { return }
                        model.usage?.scannedFiles = progress.scannedFiles
                        model.usage?.scannedFolders = progress.scannedFolders
                        model.usage?.currentPath = progress.currentPath
                        model.usage?.scanPhase = progress.phase
                    }
                },
                shouldContinue: { !Task.isCancelled }
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard model.usageGeneration == generation else { return }
                model.usage?.isScanning = false
                model.usage?.result = result
                if result != nil { model.usage?.sizesStale = false }
            }
        }
    }

    func cancelUsageScan() {
        let wasScanning = usage?.isScanning == true
        usageTask?.cancel()
        usageTask = nil
        usageGeneration += 1
        usage?.isScanning = false
        usage?.currentPath = ""
        if wasScanning { usage?.scanWasCancelled = true }
    }

    @discardableResult
    func trashUsageFile(_ file: UsageNode) async -> String? {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
        } catch {
            return error.localizedDescription
        }
        if let driveID = usage?.driveID {
            history.addEvent(driveID: driveID, kind: "cleanup", message: "Moved \(file.name) (\(ByteFormat.bytes(file.size))) to the Trash.")
        }
        usage?.result?.largestFiles.removeAll { $0.path == file.path }
        usage?.sizesStale = true
        return nil
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func react(to drives: [DriveSnapshot]) {
        for drive in drives {
            // A failed read is not an observed deterioration or recovery. Keep the
            // last successful baselines intact until this drive reports health again.
            guard drive.hasHealthReading else { continue }
            let degraded = trackIndicatorChanges(drive)
            let previous = previousStatus[drive.id]
            if let previous, previous < drive.smartStatus {
                history.addEvent(driveID: drive.id, kind: "status", message: "Status changed to \(drive.smartStatus.title).")
                notify(title: drive.displayName, body: alertBody(drive: drive, degraded: degraded))
            } else if previous == nil && drive.smartStatus >= .warning {
                notify(title: drive.displayName, body: drive.verdict)
            } else if !degraded.isEmpty {
                notify(title: drive.displayName, body: alertBody(drive: drive, degraded: degraded))
            }
            previousStatus[drive.id] = drive.smartStatus
            if let progress = drive.selfTestProgress, progress.percent < 100 {
                selfTestWasRunning.insert(drive.id)
            } else if selfTestWasRunning.contains(drive.id) {
                selfTestWasRunning.remove(drive.id)
                history.addEvent(driveID: drive.id, kind: "self-test", message: "A self-test finished.")
            }
            if let bytes = drive.bytesWritten, let previousBytes = histories[drive.id]?.dropLast().last?.bytesWritten, bytes > UInt64(previousBytes) + 50_000_000_000 {
                history.addEvent(driveID: drive.id, kind: "bytes", message: "Writes jumped by \(ByteFormat.bytes(bytes - UInt64(previousBytes))).")
            }
        }
    }

    /// Compares this scan's per-attribute statuses against the previous scan, logs a
    /// history event for every change, and returns the attributes that got worse.
    /// This is the DriveDX-style alerting: each attribute is watched on its own, so a
    /// value creeping toward its threshold is flagged even while the drive-level
    /// status stays the same.
    private func trackIndicatorChanges(_ drive: DriveSnapshot) -> [HealthIndicator] {
        let previous = previousIndicatorStatuses[drive.id]
        var updated: [Int: IndicatorStatus] = [:]
        var degraded: [HealthIndicator] = []
        for indicator in drive.indicators {
            updated[indicator.id] = indicator.status
            guard let before = previous?[indicator.id] else { continue }
            if before < indicator.status, indicator.status != .ok {
                degraded.append(indicator)
                history.addEvent(
                    driveID: drive.id,
                    kind: "indicator",
                    message: "\(indicator.name) changed from \(before.title) to \(indicator.status.title). \(indicator.explanation)"
                )
            } else if before != indicator.status, indicator.status == .ok {
                history.addEvent(driveID: drive.id, kind: "indicator", message: "\(indicator.name) returned to OK.")
            }
        }
        previousIndicatorStatuses[drive.id] = updated
        return degraded
    }

    private func alertBody(drive: DriveSnapshot, degraded: [HealthIndicator]) -> String {
        guard let first = degraded.first else { return drive.verdict }
        let names = degraded.map(\.name).joined(separator: ", ")
        return "\(names) — \(first.status.title). \(drive.verdict)"
    }

    private func notify(title: String, body: String) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleTimer(seconds: TimeInterval? = nil) {
        timer?.invalidate()
        let interval = seconds ?? 30 * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func holdSleepAssertion() {
        if sleepAssertion != 0 { return }
        let name = "DriveClue full self-test" as CFString
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &sleepAssertion)
        sleepAssertionHeld = result == kIOReturnSuccess
    }

    private func releaseSleepAssertion() {
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        sleepAssertionHeld = false
    }
}

enum ReportFormat {
    case text, csv, json
}

struct UsageScanState {
    var driveID: String
    var volumeBSD: String
    var volumePath: String
    var volumeName: String
    var isScanning: Bool
    var startedAt: Date
    var scannedFiles = 0
    var scannedFolders = 0
    var currentPath = ""
    var scanPhase: UsageScanPhase = .scanning
    var result: UsageScanResult?
    var sizesStale = false
    var scanWasCancelled = false
}
