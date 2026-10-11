import XCTest
@testable import DriveClueCore

private final class BenchmarkCounter: @unchecked Sendable {
    var value = 0
}

private final class BenchmarkProgressCollector: @unchecked Sendable {
    var phases: [DiskBenchmarkPhase] = []
}

final class DiskBenchmarkTests: XCTestCase {
    func testUnwritableDirectoryReportsCreationFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveclue-unwritable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        XCTAssertThrowsError(try DiskBenchmark.run(volumePath: directory.path, testSize: 4096)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Could not create"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("doesn’t exist"))
        }
    }

    func testSequentialBenchmarkWritesReadsAndCleansTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveclue-benchmark-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try DiskBenchmark.run(
            volumePath: directory.path,
            testSize: 1_000_000
        )

        XCTAssertEqual(result.testSize, 1_000_000)
        XCTAssertGreaterThan(result.writeMBps, 0)
        XCTAssertGreaterThan(result.readMBps, 0)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(entries.isEmpty)
    }

    func testFourPassBenchmarkReportsEachRoundAndAverages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveclue-benchmark-rounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = BenchmarkProgressCollector()

        let result = try DiskBenchmark.run(
            volumePath: directory.path,
            testSize: 1_000_000,
            passes: .four,
            progress: { progress.phases.append($0.phase) }
        )

        XCTAssertEqual(result.rounds.count, 4)
        XCTAssertEqual(result.rounds.map(\.round), [1, 2, 3, 4])
        XCTAssertEqual(result.writeMBps, result.rounds.map(\.writeMBps).reduce(0, +) / 4, accuracy: 0.0001)
        XCTAssertEqual(result.readMBps, result.rounds.map(\.readMBps).reduce(0, +) / 4, accuracy: 0.0001)
        // One write→read reset per round (4) plus one between rounds (3).
        XCTAssertEqual(progress.phases.filter { $0 == .resetting }.count, 7)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancellationBetweenPassesRemovesTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveclue-benchmark-round-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progressEvents = BenchmarkCounter()

        XCTAssertThrowsError(try DiskBenchmark.run(
            volumePath: directory.path,
            testSize: 1_000_000,
            passes: .four,
            shouldContinue: {
                progressEvents.value += 1
                return progressEvents.value < 10
            }
        )) { error in
            XCTAssertEqual(error as? DiskBenchmarkError, .cancelled)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancellationRemovesTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveclue-benchmark-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try DiskBenchmark.run(
            volumePath: directory.path,
            testSize: 1_000_000,
            shouldContinue: { false }
        )) { error in
            XCTAssertEqual(error as? DiskBenchmarkError, .cancelled)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(entries.isEmpty)
    }
}
