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
    var settings: AppSettings
    var isRefreshing = false
    var histories: [String: [HistorySample]] = [:]
    var events: [String: [DriveEvent]] = [:]
    var indicatorQuery = ""
    var typeFilter: TypeFilter = .any
    var statusFilter: StatusFilter = .any
    var selectedIndicatorID: Int?
    var freeSpaceTarget: VolumeInfo?
    var alertText: String?
    var sleepAssertionHeld = false

    let history = HistoryStore()
    private var timer: Timer?
    private var previousStatus: [String: IndicatorStatus] = [:]
    private var selfTestWasRunning: Set<String> = []
    private var sleepAssertion: IOPMAssertionID = 0
    private var ioErrorPass = false

    init() {
        settings = AppSettings.load()
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
        applyActivationPolicy()
        scheduleTimer()
        await refresh()
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        if settings.menuBarOnly {
            for window in NSApp.windows where window.canBecomeMain {
                window.orderOut(nil)
            }
        }
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        let includeIO = ioErrorPass
        ioErrorPass = false
        let scanned = await Task.detached(priority: .userInitiated) {
            DriveReader.scan { name in
                includeIO ? IOErrorCounter.count(bsdName: name) : 0
            }
        }.value
        let stamped = history.applyDeltas(scanned)
        history.record(stamped)
        drives = stamped
        if selection == nil, let first = stamped.first {
            selection = SidebarSelection(driveID: first.id, page: .dashboard)
        } else if let selection, !stamped.contains(where: { $0.id == selection.driveID }) {
            self.selection = stamped.first.map { SidebarSelection(driveID: $0.id, page: .dashboard) }
        }
        for drive in stamped {
            histories[drive.id] = history.samples(driveID: drive.id)
            events[drive.id] = history.events(driveID: drive.id)
        }
        react(to: stamped)
        isRefreshing = false
        let busy = stamped.contains { $0.selfTestProgress != nil }
        scheduleTimer(seconds: busy ? 5 : nil)
        if !busy { releaseSleepAssertion() }
    }

    func refreshWithIOErrors() async {
        ioErrorPass = true
        await refresh()
    }

    func saveSettings() {
        settings.save()
        applyActivationPolicy()
        scheduleTimer()
        updateLoginItem()
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
        try? payload.write(to: url)
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

    func checkForUpdates() async {
        alertText = await UpdateChecker.summary(feed: settings.updateFeedURL)
    }

    private func react(to drives: [DriveSnapshot]) {
        for drive in drives {
            let previous = previousStatus[drive.id]
            if let previous, previous < drive.smartStatus {
                history.addEvent(driveID: drive.id, kind: "status", message: "Status changed to \(drive.smartStatus.title).")
                notify(title: drive.displayName, body: drive.verdict)
            } else if previous == nil && drive.smartStatus >= .warning {
                notify(title: drive.displayName, body: drive.verdict)
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
        for alert in FreeSpaceMonitor.alerts(drives: drives, thresholds: settings.freeSpaceThresholds) {
            notify(title: "\(alert.volumeName) is low on space", body: "\(alert.freePercent)% free. Your limit is \(alert.threshold)%.")
            history.addEvent(driveID: drives.first { $0.volumes.contains { $0.bsdName == alert.bsdName } }?.id ?? "", kind: "space", message: "\(alert.volumeName) has \(alert.freePercent)% free.")
        }
        if settings.weeklyAllClear, drives.allSatisfy({ $0.smartStatus == .ok && $0.issueCount == 0 }) {
            let last = UserDefaults.standard.object(forKey: "DriveStats.lastAllClear") as? Date ?? .distantPast
            if Date().timeIntervalSince(last) > 7 * 24 * 3600 {
                notify(title: "Drives look healthy", body: "Every drive DriveClue can read is still OK.")
                UserDefaults.standard.set(Date(), forKey: "DriveStats.lastAllClear")
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleTimer(seconds: TimeInterval? = nil) {
        timer?.invalidate()
        let interval = seconds ?? TimeInterval(max(settings.checkIntervalMinutes, 1) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.menuBarOnly ? .accessory : .regular)
    }

    private func updateLoginItem() {
        if settings.launchAtLogin {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
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

enum TypeFilter: String, CaseIterable, Identifiable {
    case any = "Any Type"
    case preFail = "Pre-Fail"
    case lifeSpan = "Life-Span"
    var id: String { rawValue }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case any = "Any Status"
    case ok = "OK"
    case warning = "Warning"
    case failing = "Failing"
    case failed = "Failed"
    var id: String { rawValue }
}

enum ReportFormat {
    case text, csv, json
}

enum IndicatorStyle {
    static func color(_ status: IndicatorStatus) -> Color {
        switch status {
        case .ok: DiagnosticTheme.green
        case .warning: DiagnosticTheme.amber
        case .failing: Color(red: 0.95, green: 0.52, blue: 0.20)
        case .failed: DiagnosticTheme.red
        }
    }

    static func color(_ band: HealthBand) -> Color {
        switch band {
        case .good: DiagnosticTheme.green
        case .average: DiagnosticTheme.amber
        case .low: Color(red: 0.95, green: 0.52, blue: 0.20)
        case .bad: DiagnosticTheme.red
        }
    }
}
