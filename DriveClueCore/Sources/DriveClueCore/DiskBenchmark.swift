import Darwin
import Foundation

/// The sizes offered by the benchmark UI. Decimal labels match the units used by
/// Blackmagic Disk Speed Test and most drive specifications.
public enum DiskBenchmarkSize: UInt64, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case halfGB = 512_000_000
    case oneGB = 1_000_000_000
    case fourGB = 4_000_000_000

    public var id: UInt64 { rawValue }

    public var title: String {
        switch self {
        case .halfGB: "512 MB"
        case .oneGB: "1 GB"
        case .fourGB: "4 GB"
        }
    }
}

/// Number of complete sequential write/read passes. Four passes is the
/// default so short tests include the sustained behavior users see in
/// Blackmagic Disk Speed Test. Continuous mode keeps running until cancelled.
public enum DiskBenchmarkPasses: Int, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case one = 1
    case four = 4
    case continuous = 0

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .one: "1 pass"
        case .four: "4 passes"
        case .continuous: "Continuous"
        }
    }

    public var count: Int? { self == .continuous ? nil : rawValue }
}

public enum DiskBenchmarkPhase: String, Codable, Sendable {
    case preparing
    case writing
    case reading
    case resetting
    case finished

    public var title: String {
        switch self {
        case .preparing: "Preparing"
        case .writing: "Writing"
        case .reading: "Reading"
        case .resetting: "Resetting"
        case .finished: "Finished"
        }
    }
}

public struct DiskBenchmarkProgress: Codable, Sendable, Equatable {
    public var phase: DiskBenchmarkPhase
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    public var currentMBps: Double?
    public var round: Int
    public var totalRounds: Int?

    public init(phase: DiskBenchmarkPhase, completedBytes: UInt64, totalBytes: UInt64, currentMBps: Double? = nil, round: Int = 1, totalRounds: Int? = nil) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentMBps = currentMBps
        self.round = round
        self.totalRounds = totalRounds
    }
}

public struct DiskBenchmarkRoundResult: Codable, Sendable, Equatable, Identifiable {
    public var round: Int
    public var writeMBps: Double
    public var readMBps: Double
    public var writeDuration: TimeInterval
    public var readDuration: TimeInterval

    public init(round: Int, writeMBps: Double, readMBps: Double, writeDuration: TimeInterval, readDuration: TimeInterval) {
        self.round = round
        self.writeMBps = writeMBps
        self.readMBps = readMBps
        self.writeDuration = writeDuration
        self.readDuration = readDuration
    }

    public var id: Int { round }
}

public struct DiskBenchmarkResult: Codable, Sendable, Equatable {
    public var testSize: UInt64
    public var writeMBps: Double
    public var readMBps: Double
    public var writeDuration: TimeInterval
    public var readDuration: TimeInterval
    public var rounds: [DiskBenchmarkRoundResult]
    public var completedAt: Date

    public init(
        testSize: UInt64,
        writeMBps: Double,
        readMBps: Double,
        writeDuration: TimeInterval,
        readDuration: TimeInterval,
        rounds: [DiskBenchmarkRoundResult] = [],
        completedAt: Date = Date()
    ) {
        self.testSize = testSize
        self.writeMBps = writeMBps
        self.readMBps = readMBps
        self.writeDuration = writeDuration
        self.readDuration = readDuration
        self.rounds = rounds
        self.completedAt = completedAt
    }
}

public enum DiskBenchmarkError: LocalizedError, Sendable, Equatable {
    case invalidVolume
    case notEnoughSpace(available: UInt64, required: UInt64)
    case cancelled
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVolume:
            "The selected volume is not mounted or cannot be written."
        case let .notEnoughSpace(available, required):
            "The benchmark needs \(ByteFormat.bytes(required)) free; only \(ByteFormat.bytes(available)) is available."
        case .cancelled:
            "The benchmark was cancelled."
        case let .io(message):
            message
        }
    }
}

/// Runs a sequential filesystem benchmark without touching existing user data.
/// A temporary file is written, flushed, read back with caching disabled, and
/// removed even when the operation is cancelled or fails.
public enum DiskBenchmark {
    private static let chunkSize = 8 * 1024 * 1024
    private static let safetyReserve = 64 * 1_000_000
    /// Breathers between phases and rounds. They give the readouts time to
    /// drain to zero so the UI can animate the hand-off instead of snapping.
    private static let interPhaseDelay: TimeInterval = 0.4
    private static let interRoundDelay: TimeInterval = 0.8

    /// Prefer the user's temporary directory only when it is on the target
    /// filesystem. External drives must never silently benchmark the boot disk.
    public static func defaultDirectory(volumePath: String, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL? {
        let mount = URL(fileURLWithPath: volumePath, isDirectory: true)
        return [temporaryDirectory, mount].first {
            isOnVolume(directory: $0, volumePath: volumePath) && FileManager.default.isWritableFile(atPath: $0.path)
        }
    }

    public static func isOnVolume(directory: URL, volumePath: String) -> Bool {
        var directoryInfo = stat()
        var volumeInfo = stat()
        guard stat(directory.path, &directoryInfo) == 0,
              stat(volumePath, &volumeInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              volumeInfo.st_mode & S_IFMT == S_IFDIR else { return false }
        return directoryInfo.st_dev == volumeInfo.st_dev
    }

    public static func run(
        volumePath: String,
        testSize: UInt64,
        directoryPath: String? = nil,
        passes: DiskBenchmarkPasses = .four,
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled },
        progress: @escaping @Sendable (DiskBenchmarkProgress) -> Void = { _ in }
    ) throws -> DiskBenchmarkResult {
        let root = URL(fileURLWithPath: directoryPath ?? volumePath, isDirectory: true)
        guard isOnVolume(directory: root, volumePath: volumePath) else {
            throw DiskBenchmarkError.invalidVolume
        }

        let available = try availableCapacity(at: root)
        let required = testSize &+ UInt64(safetyReserve)
        guard available >= required else {
            throw DiskBenchmarkError.notEnoughSpace(available: available, required: required)
        }
        try checkContinue(shouldContinue)

        let fileURL = root.appendingPathComponent(".driveclue-benchmark-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            try Data().write(to: fileURL, options: .withoutOverwriting)
        } catch {
            throw DiskBenchmarkError.io("Could not create the temporary test file in \(root.path): \(error.localizedDescription) Choose a writable folder on this volume.")
        }
        let totalBytes = passes.count.map { testSize * 2 * UInt64($0) } ?? testSize * 2
        let totalRounds = passes.count
        progress(DiskBenchmarkProgress(phase: .preparing, completedBytes: 0, totalBytes: totalBytes, totalRounds: totalRounds))

        let chunk = Data(repeating: 0xA5, count: chunkSize)
        var roundResults: [DiskBenchmarkRoundResult] = []
        var round = 1
        while passes == .continuous || round <= (passes.count ?? 0) {
            try checkContinue(shouldContinue)
            let baseBytes = passes.count.map { _ in UInt64(round - 1) * testSize * 2 } ?? 0
            let writeStart = DispatchTime.now().uptimeNanoseconds
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try setNoCache(handle)
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                var completed: UInt64 = 0
                progress(DiskBenchmarkProgress(phase: .writing, completedBytes: baseBytes, totalBytes: totalBytes, round: round, totalRounds: totalRounds))
                while completed < testSize {
                    try checkContinue(shouldContinue)
                    let amount = Int(min(UInt64(chunk.count), testSize - completed))
                    try handle.write(contentsOf: chunk.prefix(amount))
                    completed += UInt64(amount)
                    progress(DiskBenchmarkProgress(phase: .writing, completedBytes: baseBytes + completed, totalBytes: totalBytes, currentMBps: rate(bytes: completed, seconds: elapsedSeconds(since: writeStart)), round: round, totalRounds: totalRounds))
                }
                try handle.synchronize()
            } catch let error as DiskBenchmarkError {
                throw error
            } catch {
                throw DiskBenchmarkError.io("Write benchmark failed: \(error.localizedDescription)")
            }
            let writeDuration = elapsedSeconds(since: writeStart)
            try checkContinue(shouldContinue)
            progress(DiskBenchmarkProgress(phase: .resetting, completedBytes: baseBytes + testSize, totalBytes: totalBytes, round: round, totalRounds: totalRounds))
            try pause(interPhaseDelay, shouldContinue: shouldContinue)
            let readStart = DispatchTime.now().uptimeNanoseconds
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try setNoCache(handle)
                var completed: UInt64 = 0
                progress(DiskBenchmarkProgress(phase: .reading, completedBytes: baseBytes + testSize, totalBytes: totalBytes, round: round, totalRounds: totalRounds))
                while completed < testSize {
                    try checkContinue(shouldContinue)
                    let amount = Int(min(UInt64(chunkSize), testSize - completed))
                    guard let data = try handle.read(upToCount: amount), data.count == amount else {
                        throw DiskBenchmarkError.io("Read benchmark reached the end of the test file early.")
                    }
                    completed += UInt64(data.count)
                    progress(DiskBenchmarkProgress(phase: .reading, completedBytes: baseBytes + testSize + completed, totalBytes: totalBytes, currentMBps: rate(bytes: completed, seconds: elapsedSeconds(since: readStart)), round: round, totalRounds: totalRounds))
                }
            } catch let error as DiskBenchmarkError {
                throw error
            } catch {
                throw DiskBenchmarkError.io("Read benchmark failed: \(error.localizedDescription)")
            }
            let readDuration = elapsedSeconds(since: readStart)
            roundResults.append(DiskBenchmarkRoundResult(round: round, writeMBps: rate(bytes: testSize, seconds: writeDuration), readMBps: rate(bytes: testSize, seconds: readDuration), writeDuration: writeDuration, readDuration: readDuration))
            if passes == .continuous || round < (passes.count ?? 0) {
                try checkContinue(shouldContinue)
                progress(DiskBenchmarkProgress(
                    phase: .resetting,
                    completedBytes: baseBytes + testSize * 2,
                    totalBytes: totalBytes,
                    round: round,
                    totalRounds: totalRounds
                ))
                try pause(interRoundDelay, shouldContinue: shouldContinue)
            }
            round += 1
        }

        let writeDuration = roundResults.reduce(0) { $0 + $1.writeDuration }
        let readDuration = roundResults.reduce(0) { $0 + $1.readDuration }
        let result = DiskBenchmarkResult(
            testSize: testSize,
            writeMBps: roundResults.map(\.writeMBps).reduce(0, +) / Double(max(roundResults.count, 1)),
            readMBps: roundResults.map(\.readMBps).reduce(0, +) / Double(max(roundResults.count, 1)),
            writeDuration: writeDuration,
            readDuration: readDuration,
            rounds: roundResults
        )
        progress(DiskBenchmarkProgress(
            phase: .finished,
            completedBytes: totalBytes,
            totalBytes: totalBytes,
            currentMBps: result.readMBps,
            round: max(round - 1, 1),
            totalRounds: totalRounds
        ))
        return result
    }

    private static func availableCapacity(at url: URL) throws -> UInt64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]
        do {
            let values = try url.resourceValues(forKeys: keys)
            guard let regular = values.volumeAvailableCapacity else { throw DiskBenchmarkError.invalidVolume }
            let bytes = Int64(regular)
            return UInt64(max(bytes, 0))
        } catch let error as DiskBenchmarkError {
            throw error
        } catch {
            throw DiskBenchmarkError.io("Could not read the selected volume's free space: \(error.localizedDescription)")
        }
    }

    private static func setNoCache(_ handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_NOCACHE, 1) == 0 else {
            throw DiskBenchmarkError.io("Could not disable filesystem caching for the benchmark file.")
        }
    }

    private static func checkContinue(_ shouldContinue: @Sendable () -> Bool) throws {
        guard shouldContinue() else { throw DiskBenchmarkError.cancelled }
    }

    /// Sleeps in short steps so cancelling during a pause takes effect quickly.
    private static func pause(_ interval: TimeInterval, shouldContinue: @Sendable () -> Bool) throws {
        let step: TimeInterval = 0.05
        var remaining = interval
        while remaining > 0 {
            try checkContinue(shouldContinue)
            Thread.sleep(forTimeInterval: min(step, remaining))
            remaining -= step
        }
    }

    private static func elapsedSeconds(since start: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return max(Double(now - start) / 1_000_000_000, 0.000_001)
    }

    private static func rate(bytes: UInt64, seconds: TimeInterval) -> Double {
        Double(bytes) / 1_000_000 / max(seconds, 0.000_001)
    }
}
