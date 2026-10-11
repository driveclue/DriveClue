import DriveClueCore
import Foundation

struct DiskBenchmarkState: Equatable {
    var driveID: String
    var volumeBSD: String
    var volumeName: String
    var testSize: DiskBenchmarkSize
    var passes: DiskBenchmarkPasses
    var directoryPath: String
    var isRunning = true
    var progress: DiskBenchmarkProgress
    var writeSpeed: Double? = nil
    var readSpeed: Double? = nil
    var result: DiskBenchmarkResult?
    var error: String?
}
