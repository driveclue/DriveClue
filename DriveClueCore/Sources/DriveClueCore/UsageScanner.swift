import Foundation

/// A folder or file in the storage breakdown. Folder nodes aggregate the allocated
/// size and file count of everything below them; `truncated` marks places where the
/// tree was summarized (too deep, or too many children to list).
public struct UsageNode: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var size: UInt64
    public var fileCount: Int
    public var directories: [UsageNode]
    public var files: [UsageNode]
    public var isDirectory: Bool
    public var truncated: Bool

    init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.size = 0
        self.fileCount = 0
        self.directories = []
        self.files = []
        self.isDirectory = isDirectory
        self.truncated = false
    }
}

public struct UsageScanResult: Equatable, Sendable {
    public var volumeName: String
    public var volumePath: String
    public var root: UsageNode
    public var largestFiles: [UsageNode]
    public var scannedFiles: Int
    public var unreadableEntries: Int
    public var unreadablePaths: [String]
    public var rootReadError: String?
}

public enum UsageScanPhase: Sendable, Equatable {
    case scanning
    case finalizing
}

public struct UsageScanProgress: Sendable {
    public var scannedFiles: Int
    public var scannedFolders: Int
    public var currentPath: String
    public var phase: UsageScanPhase
}

/// Walks one mounted volume and builds a size breakdown without needing elevated
/// access. Directory listings fan out across a bounded task group so filesystem
/// metadata requests can overlap on SSDs; their results are then folded bottom-up
/// into the displayed tree. Directories that live on another filesystem than the
/// scan root are detected via `st_dev` and skipped, avoiding unrelated mounted
/// volumes. A scan rooted at "/" also reaches firmlinked Data volume directories,
/// which are exempted from that check by an allowlist.
public enum UsageScanner {
    private static let maxDepth = 10
    private static let maxChildrenPerNode = 400
    private static let largeFileLimit = 60

    // When the scan starts at "/", these mounts duplicate content counted elsewhere
    // (firmlinked Data volume, other disks, autofs) and would double-count.
    private static let rootOnlySkipPrefixes = ["/System/Volumes/", "/Volumes/", "/dev/", "/home/", "/net/"]

    // Firmlink targets reachable from "/" that live on the Data volume. Their st_dev
    // differs from the root volume's even though they are part of the scanned space,
    // so the mount-boundary check must not treat them as foreign mounts.
    private static let firmlinkTargets: Set<String> = [
        "/Applications", "/Library", "/Users", "/opt", "/usr/local",
        "/private", "/private/etc", "/private/tmp", "/private/var"
    ]

    private static let systemEntryNames: Set<String> = [
        ".Spotlight-V100", ".Trashes", ".DocumentRevisions-V100", ".fseventsd",
        ".TemporaryItems", ".MobileBackups", ".PKInstallSandboxManagerSystemSoftware"
    ]

    private struct FileEntry: Sendable {
        let path: String
        let size: UInt64
    }

    /// Raw listing result for one directory, produced by a worker task.
    private struct DirRecord: Sendable {
        var ownSize: UInt64 = 0
        var ownFiles = 0
        var unreadable = false
        var readError: String?
        var entriesUnreadable = 0
        var unreadablePaths: [String] = []
        var filesTruncated = false
        var subdirectories: [String] = []
        var files: [FileEntry] = []
    }

    private struct DirReport: Sendable {
        let path: String
        let depth: Int
        let deviceID: UInt64
        let foreignMount: Bool
        let record: DirRecord
        let largeFiles: [UsageNode]
    }

    public static func scan(
        rootPath: String,
        volumeName: String,
        largeFileMinimum: UInt64 = 64_000_000,
        progress: (@Sendable (UsageScanProgress) -> Void)? = nil,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async -> UsageScanResult? {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let rootPath = rootURL.path
        let isFilesystemRoot = rootPath == "/"
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let concurrency = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))

        var records: [String: DirRecord] = [:]
        var scannedFiles = 0
        var scannedFolders = 0
        var unreadable = 0
        var unreadablePaths: [String] = []
        var largeFiles: [UsageNode] = []
        var sawCancellation = false
        var lastReported = Date.distantPast
        var dirsSinceReport = 0

        func reportProgress(_ path: String, phase: UsageScanPhase = .scanning) {
            progress?(UsageScanProgress(
                scannedFiles: scannedFiles,
                scannedFolders: scannedFolders,
                currentPath: path,
                phase: phase
            ))
        }

        // The walk is breadth-first with a bounded number of in-flight directory
        // listings. Completed reports carry the subdirectories to enqueue next, so
        // the coordinator stays the only writer of every accumulation variable and
        // no locking is needed.
        var pending: [(path: String, depth: Int, parentDeviceID: UInt64)] = []
        var pendingIndex = 0
        var inFlight = 0

        await withTaskGroup(of: DirReport?.self) { group in
            func enqueue(_ path: String, depth: Int, parentDeviceID: UInt64) {
                inFlight += 1
                group.addTask {
                    await visitDirectory(
                        path: path,
                        scanRootPath: rootPath,
                        depth: depth,
                        parentDeviceID: parentDeviceID,
                        isFilesystemRoot: isFilesystemRoot,
                        largeFileMinimum: largeFileMinimum,
                        keys: keys,
                        shouldContinue: shouldContinue
                    )
                }
            }

            enqueue(rootPath, depth: 0, parentDeviceID: 0)

            while let report = await group.next() {
                inFlight -= 1
                guard let report else {
                    sawCancellation = true
                    group.cancelAll()
                    continue
                }
                if sawCancellation { continue }
                if !report.foreignMount {
                    scannedFolders += 1
                    scannedFiles += report.record.ownFiles
                    unreadable += (report.record.unreadable ? 1 : 0) + report.record.entriesUnreadable
                    unreadablePaths.append(contentsOf: report.record.unreadablePaths)
                    largeFiles.append(contentsOf: report.largeFiles)
                    if largeFiles.count > largeFileLimit {
                        largeFiles.sort { $0.size > $1.size }
                        largeFiles.removeLast(largeFiles.count - largeFileLimit)
                    }
                    records[report.path] = report.record
                    for subdirectory in report.record.subdirectories {
                        pending.append((subdirectory, report.depth + 1, report.deviceID))
                    }
                }

                while inFlight < concurrency, pendingIndex < pending.count {
                    let next = pending[pendingIndex]
                    pendingIndex += 1
                    enqueue(next.path, depth: next.depth, parentDeviceID: next.parentDeviceID)
                }

                dirsSinceReport += 1
                let now = Date()
                if dirsSinceReport >= 64 || now.timeIntervalSince(lastReported) >= 0.5 {
                    dirsSinceReport = 0
                    lastReported = now
                    reportProgress(report.path)
                }
            }
        }

        if sawCancellation { return nil }

        reportProgress(rootPath, phase: .finalizing)
        largeFiles.sort { $0.size > $1.size }
        reportProgress(rootPath)

        // Bottom-up totals for every reached directory, used to sort children by
        // size and to accrue summarized subtrees into their nearest tracked
        // ancestor. Iterative post-order because directory depth is unbounded.
        var totals: [String: (size: UInt64, files: Int)] = [:]
        struct TotalsFrame {
            let path: String
            let subdirectories: [String]
            var index: Int
            var size: UInt64
            var files: Int
        }
        if let rootRecord = records[rootPath] {
            var stack = [TotalsFrame(path: rootPath, subdirectories: rootRecord.subdirectories, index: 0, size: rootRecord.ownSize, files: rootRecord.ownFiles)]
            while let frame = stack.last {
                if frame.index < frame.subdirectories.count {
                    let top = stack.count - 1
                    let subdirectory = stack[top].subdirectories[stack[top].index]
                    stack[top].index += 1
                    guard let record = records[subdirectory], totals[subdirectory] == nil else { continue }
                    stack.append(TotalsFrame(path: subdirectory, subdirectories: record.subdirectories, index: 0, size: record.ownSize, files: record.ownFiles))
                } else {
                    totals[frame.path] = (frame.size, frame.files)
                    stack.removeLast()
                    if !stack.isEmpty {
                        stack[stack.count - 1].size += frame.size
                        stack[stack.count - 1].files += frame.files
                    }
                }
            }
        }

        func buildNode(path: String, name: String, depth: Int) -> UsageNode {
            var node = UsageNode(path: path, name: name, isDirectory: true)
            guard let record = records[path] else { return node }
            node.size = record.ownSize
            node.fileCount = record.ownFiles
            if record.unreadable || record.entriesUnreadable > 0 || record.filesTruncated {
                node.truncated = true
            }
            node.files = record.files
                .sorted { $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size }
                .map { entry in
                    var file = UsageNode(path: entry.path, name: URL(fileURLWithPath: entry.path).lastPathComponent, isDirectory: false)
                    file.size = entry.size
                    return file
                }

            let trackable = record.subdirectories.filter { records[$0] != nil }
            if trackable.count < record.subdirectories.count {
                node.truncated = true
            }
            let sorted = trackable.sorted {
                let left = totals[$0]?.size ?? 0
                let right = totals[$1]?.size ?? 0
                return left == right ? $0 < $1 : left > right
            }
            // Deep folders stay untracked: their contents accrue to the nearest
            // tracked ancestor via the totals table, which is marked summarized.
            let trackedCount = depth < maxDepth ? min(sorted.count, maxChildrenPerNode) : 0
            if sorted.count > trackedCount {
                node.truncated = true
            }
            for subdirectory in sorted.prefix(trackedCount) {
                let child = buildNode(
                    path: subdirectory,
                    name: URL(fileURLWithPath: subdirectory).lastPathComponent,
                    depth: depth + 1
                )
                node.size += child.size
                node.fileCount += child.fileCount
                node.directories.append(child)
            }
            for subdirectory in sorted.dropFirst(trackedCount) {
                node.size += totals[subdirectory]?.size ?? 0
                node.fileCount += totals[subdirectory]?.files ?? 0
            }
            return node
        }

        return UsageScanResult(
            volumeName: volumeName,
            volumePath: rootPath,
            root: buildNode(path: rootPath, name: rootURL.lastPathComponent.isEmpty ? "/" : rootURL.lastPathComponent, depth: 0),
            largestFiles: Array(largeFiles.prefix(largeFileLimit)),
            scannedFiles: scannedFiles,
            unreadableEntries: unreadable,
            unreadablePaths: Array(unreadablePaths.prefix(200)),
            rootReadError: records[rootPath]?.readError
        )
    }

    /// Lists one directory. Returns `nil` only when the scan should stop; a
    /// directory that cannot be read is reported as unreadable so the walk keeps
    /// going, and a directory on another filesystem is reported as a foreign mount
    /// so its space is neither walked nor counted.
    private static func visitDirectory(
        path: String,
        scanRootPath: String,
        depth: Int,
        parentDeviceID: UInt64,
        isFilesystemRoot: Bool,
        largeFileMinimum: UInt64,
        keys: [URLResourceKey],
        shouldContinue: @Sendable () -> Bool
    ) async -> DirReport? {
        if !shouldContinue() { return nil }

        var status = stat()
        guard stat(path, &status) == 0 else {
            var record = DirRecord()
            record.unreadable = true
            record.readError = String(cString: strerror(errno))
            record.unreadablePaths = [path]
            return DirReport(path: path, depth: depth, deviceID: parentDeviceID, foreignMount: false, record: record, largeFiles: [])
        }
        let deviceID = UInt64(status.st_dev)
        if parentDeviceID != 0, deviceID != parentDeviceID,
           !(isFilesystemRoot && firmlinkTargets.contains(path)) {
            return DirReport(path: path, depth: depth, deviceID: deviceID, foreignMount: true, record: DirRecord(), largeFiles: [])
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        let listed: [URL]
        do {
            listed = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            var record = DirRecord()
            record.unreadable = true
            record.readError = error.localizedDescription
            record.unreadablePaths = [path]
            return DirReport(path: path, depth: depth, deviceID: deviceID, foreignMount: false, record: record, largeFiles: [])
        }

        var record = DirRecord()
        var largeFiles: [UsageNode] = []
        for (index, entry) in listed.enumerated() {
            if index.isMultiple(of: 2048), !shouldContinue() { return nil }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                record.entriesUnreadable += 1
                record.unreadablePaths.append(normalizedEntryPath(entry.path, scanRootPath: scanRootPath))
                continue
            }
            if values.isSymbolicLink == true { continue }

            let entryPath = normalizedEntryPath(entry.path, scanRootPath: scanRootPath)
            if isFilesystemRoot, rootOnlySkipPrefixes.contains(where: { entryPath.hasPrefix($0) }) { continue }
            if depth == 0, systemEntryNames.contains(entry.lastPathComponent) { continue }

            if values.isDirectory == true {
                record.subdirectories.append(entryPath)
                continue
            }

            let size = UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            record.ownSize += size
            record.ownFiles += 1
            if depth <= maxDepth {
                if record.files.count < maxChildrenPerNode {
                    record.files.append(FileEntry(path: entryPath, size: size))
                } else {
                    record.filesTruncated = true
                }
            }
            if size >= largeFileMinimum {
                var file = UsageNode(path: entryPath, name: entry.lastPathComponent, isDirectory: false)
                file.size = size
                largeFiles.append(file)
            }
        }
        return DirReport(path: path, depth: depth, deviceID: deviceID, foreignMount: false, record: record, largeFiles: largeFiles)
    }

    /// Foundation reports firmlinked Data-volume directories using their user-facing
    /// aliases (for example `/Users/trantuan`) even when the scan root is
    /// `/System/Volumes/Data`. Keep every descendant under the scanned root so
    /// navigation, breadcrumbs, and subsequent metadata reads use one path space.
    private static func normalizedEntryPath(_ path: String, scanRootPath: String) -> String {
        let dataMount = "/System/Volumes/Data"
        guard scanRootPath == dataMount || scanRootPath.hasPrefix(dataMount + "/"),
              !path.hasPrefix(dataMount + "/") else { return path }
        return dataMount + path
    }
}
