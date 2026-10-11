import XCTest
@testable import DriveClueCore

final class UsageScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-\(UUID().uuidString)", isDirectory: true)
        try write("Small/tiny.txt", bytes: 100)
        try write("Big.bin", bytes: 300)
        try write("Nested/Deep/large.dat", bytes: 5_000_000)
        try write("Viewer.app/Contents/MacOS/Viewer", bytes: 1_200_000)
        for index in 0..<410 {
            try write("Many/file\(index).txt", bytes: 10)
        }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("alias").path,
            withDestinationPath: "Big.bin"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func allocatedSize(_ relative: String) throws -> UInt64 {
        let values = try root.appendingPathComponent(relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    private func scan() async throws -> UsageScanResult {
        let result = await UsageScanner.scan(rootPath: root.path, volumeName: "Test", largeFileMinimum: 1_000_000, shouldContinue: { true })
        return try XCTUnwrap(result)
    }

    func testAggregatesSizesAndSkipsSymlinks() async throws {
        let result = try await scan()
        let expected = try allocatedSize("Small/tiny.txt")
            + allocatedSize("Big.bin")
            + allocatedSize("Nested/Deep/large.dat")
            + allocatedSize("Viewer.app/Contents/MacOS/Viewer")
            + 410 * allocatedSize("Many/file0.txt")
        XCTAssertEqual(result.root.size, expected)
        XCTAssertEqual(result.root.fileCount, 414)
        XCTAssertEqual(result.scannedFiles, 414)
        XCTAssertEqual(result.root.files.map(\.name), ["Big.bin"])
        // The symlink must not appear as an entry of its own.
        XCTAssertFalse(result.root.directories.contains { $0.name == "alias" })
        XCTAssertEqual(result.unreadableEntries, 0)
    }

    func testDescendsIntoPackages() async throws {
        let result = try await scan()
        let app = try XCTUnwrap(result.root.directories.first { $0.name == "Viewer.app" })
        XCTAssertEqual(app.fileCount, 1)
        XCTAssertEqual(app.size, try allocatedSize("Viewer.app/Contents/MacOS/Viewer"))
    }

    func testNestedTreeStructure() async throws {
        let result = try await scan()
        let nested = try XCTUnwrap(result.root.directories.first { $0.name == "Nested" })
        XCTAssertEqual(nested.directories.map(\.name), ["Deep"])
        XCTAssertEqual(nested.files.map(\.name), [])
        let deep = try XCTUnwrap(nested.directories.first { $0.name == "Deep" })
        XCTAssertEqual(deep.files.map(\.name), ["large.dat"])
        XCTAssertEqual(deep.size, try allocatedSize("Nested/Deep/large.dat"))
    }

    func testDataVolumeAliasKeepsDescendantsUnderScannedRoot() async throws {
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp/usage-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryRoot.appendingPathComponent("Child/Grandchild"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try Data(count: 100).write(to: temporaryRoot.appendingPathComponent("Child/Grandchild/file.txt"))
        let mountedPath = "/System/Volumes/Data" + temporaryRoot.path
        guard FileManager.default.fileExists(atPath: mountedPath) else {
            throw XCTSkip("The macOS Data mount is unavailable")
        }
        let scanned = await UsageScanner.scan(
            rootPath: mountedPath, volumeName: "Data", shouldContinue: { true }
        )
        let result = try XCTUnwrap(scanned)
        let child = try XCTUnwrap(result.root.directories.first)
        let grandchild = try XCTUnwrap(child.directories.first)
        XCTAssertEqual(child.path, mountedPath + "/Child")
        XCTAssertEqual(grandchild.path, mountedPath + "/Child/Grandchild")
        XCTAssertEqual(grandchild.files.first?.path, mountedPath + "/Child/Grandchild/file.txt")
    }

    func testCapsListedChildrenButCountsEveryFile() async throws {
        let result = try await scan()
        let many = try XCTUnwrap(result.root.directories.first { $0.name == "Many" })
        XCTAssertEqual(many.files.count, 400)
        XCTAssertTrue(many.truncated)
        XCTAssertEqual(many.fileCount, 410)
    }

    func testSummarizesExcessDirectoriesWithoutLosingTheirSizes() async throws {
        for index in 0..<410 {
            try write("Branches/branch\(index)/item.txt", bytes: 100)
        }
        let result = try await scan()
        let branches = try XCTUnwrap(result.root.directories.first { $0.name == "Branches" })
        XCTAssertEqual(branches.directories.count, 400)
        XCTAssertTrue(branches.truncated)
        XCTAssertEqual(branches.fileCount, 410)
        XCTAssertEqual(branches.size, 410 * (try allocatedSize("Branches/branch0/item.txt")))
    }

    func testLargestFilesSortedDescending() async throws {
        let result = try await scan()
        XCTAssertEqual(result.largestFiles.map(\.name), ["large.dat", "Viewer"])
    }

    func testFoldersAreSortedByAllocatedSize() async throws {
        try write("Small/extra.txt", bytes: 50)
        let result = try await scan()
        let sizes = result.root.directories.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertEqual(result.root.directories.first?.name, "Nested")
    }

    func testDeepFoldersAreSummarizedWithoutLosingTheirSizes() async throws {
        let path = (0..<12).map { "level\($0)" }.joined(separator: "/") + "/deep.bin"
        try write(path, bytes: 8_000)
        let result = try await scan()
        XCTAssertEqual(result.root.fileCount, 415)
        XCTAssertEqual(result.root.size, try allocatedSize(path)
            + allocatedSize("Small/tiny.txt")
            + allocatedSize("Big.bin")
            + allocatedSize("Nested/Deep/large.dat")
            + allocatedSize("Viewer.app/Contents/MacOS/Viewer")
            + 410 * allocatedSize("Many/file0.txt"))
        let top = try XCTUnwrap(result.root.directories.first { $0.name == "level0" })
        XCTAssertTrue(top.fileCount == 1)
        var current = top
        while let child = current.directories.first { current = child }
        XCTAssertTrue(current.truncated)
    }

    func testReadableEmptyRootIsNotAReadFailure() async throws {
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let scanned = await UsageScanner.scan(rootPath: empty.path, volumeName: "Empty", shouldContinue: { true })
        let result = try XCTUnwrap(scanned)
        XCTAssertNil(result.rootReadError)
        XCTAssertEqual(result.scannedFiles, 0)
        XCTAssertEqual(result.root.size, 0)
    }

    func testMissingRootIsNotReportedAsAnEmptyVolume() async throws {
        let missing = root.appendingPathComponent("NotMounted", isDirectory: true)
        let scanned = await UsageScanner.scan(rootPath: missing.path, volumeName: "Missing", shouldContinue: { true })
        let result = try XCTUnwrap(scanned)
        XCTAssertNotNil(result.rootReadError)
        XCTAssertEqual(result.unreadablePaths, [missing.path])
    }

    func testCancelledScanReturnsNil() async {
        let cancelled = await UsageScanner.scan(rootPath: root.path, volumeName: "Test", largeFileMinimum: 1_000_000, shouldContinue: { false })
        XCTAssertNil(cancelled)
    }

    func testReportsFileFolderAndPathProgress() async throws {
        let recorder = ProgressRecorder()
        let result = await UsageScanner.scan(
            rootPath: root.path,
            volumeName: "Test",
            progress: { recorder.record($0) },
            shouldContinue: { true }
        )
        XCTAssertNotNil(result)
        let last = try XCTUnwrap(recorder.last)
        XCTAssertEqual(last.scannedFiles, result?.scannedFiles)
        XCTAssertGreaterThan(last.scannedFolders, 1)
        XCTAssertEqual(last.currentPath, root.path)
    }

    func testReportsFinalizingPhase() async throws {
        let recorder = ProgressRecorder()
        let result = await UsageScanner.scan(
            rootPath: root.path,
            volumeName: "Test",
            progress: { recorder.record($0) },
            shouldContinue: { true }
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(recorder.phases.contains(.finalizing))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UsageScanProgress?
    private var recordedPhases: [UsageScanPhase] = []

    var last: UsageScanProgress? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var phases: [UsageScanPhase] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPhases
    }

    func record(_ progress: UsageScanProgress) {
        lock.lock()
        value = progress
        recordedPhases.append(progress.phase)
        lock.unlock()
    }
}
