import DriveClueCore
import Foundation

let drives = DriveReader.scan()
if drives.isEmpty {
    fputs("No physical disks were found.\n", stderr)
    exit(1)
}
for drive in drives {
    print("\(drive.bsdName)  \(drive.model)")
    print("  serial \(drive.serial)  firmware \(drive.firmware)")
    print("  \(ByteFormat.bytes(drive.capacityBytes))  \(drive.transport.rawValue)  health \(String(format: "%.1f", drive.overallHealth))% \(drive.healthBand.title)")
    if let life = drive.ssdLife { print("  SSD life \(String(format: "%.1f", life))%") }
    if let temp = drive.temperatureCelsius { print("  \(temp) °C") }
    if let error = drive.readError { print("  note: \(error)") }
    print("  volumes: \(drive.volumes.filter(\.isUserFacing).map(\.name).joined(separator: ", "))")
    print("  indicators: \(drive.indicators.count)  issues: \(drive.issueCount)")
    for indicator in drive.indicators.prefix(8) {
        print("    \(indicator.id) \(indicator.name) \(indicator.rawDisplay) \(indicator.status.title)")
    }
}
