import DriveClueCore
import Foundation

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "usage" {
    let path = CommandLine.arguments[2]
    let start = Date()
    let result = await UsageScanner.scan(
        rootPath: path,
        volumeName: "Probe",
        progress: { progress in
            guard progress.scannedFolders == 1 || progress.scannedFolders.isMultiple(of: 4096) else { return }
            let now = Date()
            print(String(format: "[%5.1fs] files=%8d folders=%7d at %@",
                         now.timeIntervalSince(start), progress.scannedFiles, progress.scannedFolders, progress.currentPath))
        },
        shouldContinue: { !Task.isCancelled }
    )
    guard let result else {
        fputs("Scan cancelled.\n", stderr)
        exit(2)
    }
    let elapsed = Date().timeIntervalSince(start)
    let rate = elapsed > 0 ? Int(Double(result.scannedFiles) / elapsed) : 0
    print("Scanned \(result.scannedFiles) files in \(String(format: "%.2f", elapsed))s (\(rate) files/s), unreadable=\(result.unreadableEntries)")
    print("Root total: \(ByteFormat.bytes(result.root.size))")
    exit(0)
}

let drives = DriveReader.scan()
if drives.isEmpty {
    fputs("No physical disks were found.\n", stderr)
    exit(1)
}
for drive in drives {
    print("\(drive.bsdName)  \(drive.model)")
    print("  serial \(drive.serial)  firmware \(drive.firmware)")
    print("  \(ByteFormat.bytes(drive.capacityBytes))  \(drive.transport.rawValue)  health \(drive.presentableHealth.map { String(format: "%.1f%% %@", $0, drive.presentableHealthBand?.title ?? "") } ?? "Unavailable")")
    if drive.hasHealthReading, let life = drive.ssdLife { print("  SSD life \(String(format: "%.1f", life))%") }
    if drive.hasHealthReading, let temp = drive.temperatureCelsius { print("  \(temp) °C") }
    if let error = drive.readError { print("  note: \(error)") }
    print("  volumes: \(drive.volumes.filter(\.isUserFacing).map(\.name).joined(separator: ", "))")
    print("  indicators: \(drive.indicators.count)  issues: \(drive.issueCount)")
    for indicator in drive.indicators.prefix(8) {
        print("    \(indicator.id) \(indicator.name) \(indicator.rawDisplay) \(indicator.status.title)")
    }
    print("  capabilities:")
    for capability in drive.capabilities {
        print("    \(capability.name): \(capability.value)")
    }
}
