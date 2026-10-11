import Foundation

public enum Diagnosis {
    public static func lines(for drive: DriveSnapshot) -> [String] {
        guard drive.hasHealthReading else { return [drive.readError ?? "S.M.A.R.T. health data is unavailable."] }
        var lines: [String] = []
        for indicator in drive.indicators where indicator.status != .ok {
            switch indicator.id {
            case 199:
                lines.append("CRC errors usually mean the cable, port, or enclosure. Reseat the connection before you blame the drive.")
            case 188:
                lines.append("Command timeouts often come from power or a loose cable. Watch whether the count keeps rising.")
            case 5, 196, 197, 198:
                lines.append("\(indicator.name) is no longer zero. Copy important files off this drive and plan to replace it.")
            case 11 where indicator.name.contains("Media"):
                lines.append("The SSD reported media errors. Back up, then stop using it for the only copy of anything.")
            default:
                lines.append("\(indicator.name) is \(indicator.status.title.lowercased()). \(indicator.explanation)")
            }
        }
        if let temp = drive.temperatureCelsius, let max = drive.recommendedTempMax, temp > max {
            lines.append("The drive is warmer than the typical \(max) °C range. Give it airflow and check again.")
        }
        if drive.failedSelfTests > 0 {
            lines.append("A self-test reported a failure. Back up, then run the full test once more before replacing the drive.")
        }
        var unique: [String] = []
        for line in lines where !unique.contains(line) {
            unique.append(line)
        }
        return unique
    }
}

public enum ReportBuilder {
    public static func text(drives: [DriveSnapshot]) -> String {
        var lines: [String] = []
        lines.append("DriveClue health report")
        lines.append("Generated \(timestamp(Date()))")
        lines.append("")
        for drive in drives {
            lines.append(String(repeating: "=", count: 64))
            lines.append(drive.displayName)
            lines.append("Model: \(drive.model)")
            lines.append("Family: \(drive.modelFamily)")
            lines.append("Serial: \(drive.serial.isEmpty ? "—" : drive.serial)")
            lines.append("Firmware: \(drive.firmware.isEmpty ? "—" : drive.firmware)")
            if let wwn = drive.wwn { lines.append("WWN: \(wwn)") }
            lines.append("Device: \(drive.devicePath)")
            lines.append("Capacity: \(ByteFormat.bytes(drive.capacityBytes))")
            lines.append("Sector size: \(drive.sectorSize) bytes")
            if drive.hasHealthReading {
                if let hours = drive.powerOnHours { lines.append("Power on: \(ByteFormat.durationHours(hours))") }
                if let cycles = drive.powerCycleCount { lines.append("Power cycles: \(cycles)") }
                lines.append("Status: \(drive.statusLine)\(drive.issueCount > 0 ? " · \(drive.issueCount) issue(s)" : "")")
                if let health = drive.presentableHealth, let band = drive.presentableHealthBand {
                    lines.append(String(format: "Overall health: %.1f%% %@", health, band.title))
                }
                if let performance = drive.performance, let band = drive.performanceBand {
                    lines.append(String(format: "Performance: %.1f%% %@", performance, band.title))
                }
                if let life = drive.ssdLife, let band = drive.ssdLifeBand {
                    lines.append(String(format: "SSD life left: %.1f%% %@", life, band.title))
                }
                if let temp = drive.temperatureCelsius { lines.append("Temperature: \(temp) °C") }
            } else {
                lines.append("Status: Unavailable")
                lines.append("Overall health: Unavailable")
            }
            if let error = drive.readError { lines.append("Note: \(error)") }
            let diagnosis = Diagnosis.lines(for: drive)
            if !diagnosis.isEmpty {
                lines.append("Diagnosis:")
                diagnosis.forEach { lines.append("  - \($0)") }
            }
            if drive.hasHealthReading {
                lines.append("Indicators:")
                for indicator in drive.indicators {
                    let rating = indicator.rating.map { String(format: "%.0f%%", $0) } ?? "—"
                    lines.append("  \(indicator.id) \(indicator.name): \(indicator.rawDisplay)  value \(indicator.current.map(String.init) ?? "—") / worst \(indicator.worst.map(String.init) ?? "—") / threshold \(indicator.threshold.map(String.init) ?? "—")  \(rating) \(indicator.status.title)")
                }
            }
            if drive.hasHealthReading && !drive.selfTests.isEmpty {
                lines.append("Self-tests:")
                for test in drive.selfTests.prefix(12) {
                    lines.append("  \(test.testType) at \(test.powerOnHours.map(String.init) ?? "—") h — \(test.status) — LBA \(test.failingLBA)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func csv(drives: [DriveSnapshot]) -> String {
        var lines = ["drive,id,name,raw,current,worst,threshold,rating,status"]
        for drive in drives where drive.hasHealthReading {
            for indicator in drive.indicators {
                let cells = [
                    drive.model,
                    "\(indicator.id)",
                    indicator.name,
                    indicator.rawDisplay,
                    indicator.current.map(String.init) ?? "",
                    indicator.worst.map(String.init) ?? "",
                    indicator.threshold.map(String.init) ?? "",
                    indicator.rating.map { String(format: "%.1f", $0) } ?? "",
                    indicator.status.title
                ].map(escape)
                lines.append(cells.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func json(drives: [DriveSnapshot]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(drives),
              var records = try? JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else { return Data() }
        for index in drives.indices {
            records[index]["hasHealthReading"] = drives[index].hasHealthReading
            guard !drives[index].hasHealthReading else { continue }
            // The model keeps legacy nonoptional defaults for compatibility. In an
            // exported report those defaults must not become fabricated readings.
            for key in ["overallHealth", "healthBand", "performance", "performanceBand",
                        "ssdLife", "ssdLifeBand", "smartStatus", "issueCount",
                        "powerOnHours", "powerCycleCount", "temperatureCelsius",
                        "temperatureMin", "temperatureMax", "overTemperatureMinutes",
                        "underTemperatureMinutes", "bytesWritten", "indicators",
                        "errors", "statistics", "selfTests", "selfTestProgress"] {
                records[index].removeValue(forKey: key)
            }
        }
        return (try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
