import Foundation

public enum NVMeLog {
    public static let dataUnitBytes: UInt64 = 512_000

    /// Standard NVMe SMART/health-log indicators (NVM Express §5.10.1.2 ordering, the
    /// same numbering DriveDX uses). Rows without a failure threshold use the 100%-OK
    /// presentation convention for pure counters; NVMe defines no failure semantics
    /// for them. `worst` is left nil here and filled from recorded history so the
    /// column shows a true worst-on-record instead of a copy of the current value.
    public static func indicators(raw: NVMeNumbers) -> [HealthIndicator] {
        let life = max(0, min(100, 100 - Double(raw.percentageUsed)))
        let spareRating = spareHealth(spare: raw.availableSpare, threshold: raw.spareThreshold)
        let warning = raw.criticalWarning
        return [
            row(id: 1, name: "Critical Warning", kind: .preFail, raw: UInt64(warning), display: String(format: "0x%02X", warning), current: warning == 0 ? 100 : 0, threshold: 1, rating: warning == 0 ? 100 : 0, status: warning == 0 ? .ok : .failed, explanation: criticalText(warning), important: true, health: true),
            temperatureRow(raw.temperatureCelsius),
            row(id: 3, name: "Available Spare", kind: .preFail, raw: UInt64(raw.availableSpare), display: "\(raw.availableSpare)%", current: raw.availableSpare, threshold: raw.spareThreshold, rating: spareRating, status: raw.availableSpare <= raw.spareThreshold ? .failed : (spareRating < 30 ? .warning : .ok), explanation: "Percent of spare flash still available. Failure starts at the spare threshold.", important: true, health: true),
            // SSD wear drives the lifetime indicator, not the overall health rating:
            // a half-worn drive with no errors is still a healthy drive.
            row(id: 5, name: "Percentage Used", kind: .lifeSpan, raw: UInt64(raw.percentageUsed), display: "\(raw.percentageUsed)%", current: Int(life), threshold: 0, rating: life, status: raw.percentageUsed >= 100 ? .failed : (raw.percentageUsed >= 90 ? .warning : .ok), explanation: "Vendor estimate of endurance already consumed. 100 means the rated life is used up. The drive can keep working after that.", important: true, health: false),
            counter(id: 6, name: "Data Units Read", raw: raw.dataUnitsRead, display: dataUnitsDisplay(raw.dataUnitsRead), explanation: "Host data read, in 512,000-byte data units with the total in parentheses.", important: false),
            counter(id: 7, name: "Data Units Written", raw: raw.dataUnitsWritten, display: dataUnitsDisplay(raw.dataUnitsWritten), explanation: "Host data written, in 512,000-byte data units with the total in parentheses.", important: true),
            counter(id: 8, name: "Host Read Commands", raw: raw.hostReadCommands, display: ByteFormat.decimal(raw.hostReadCommands), explanation: "Read commands the host has sent to the controller.", important: false),
            counter(id: 9, name: "Host Write Commands", raw: raw.hostWriteCommands, display: ByteFormat.decimal(raw.hostWriteCommands), explanation: "Write commands the host has sent to the controller.", important: false),
            counter(id: 10, name: "Controller Busy Time", raw: raw.controllerBusyMinutes, display: durationDisplay(minutes: raw.controllerBusyMinutes), explanation: "Time the controller spent busy with I/O commands.", important: false),
            counter(id: 11, name: "Power Cycles", raw: raw.powerCycles, display: ByteFormat.decimal(raw.powerCycles), explanation: "Times the SSD has powered on.", important: false),
            row(id: 12, name: "Power On Hours", kind: .lifeSpan, raw: raw.powerOnHours, display: ByteFormat.durationHours(Int(min(raw.powerOnHours, UInt64(Int.max)))), current: 100, threshold: 0, rating: 100, status: .ok, explanation: "Hours this SSD has been powered on.", important: true, health: false),
            counter(id: 13, name: "Unsafe Shutdowns", raw: raw.unsafeShutdowns, display: ByteFormat.decimal(raw.unsafeShutdowns), explanation: "Shutdowns that skipped a clean cache flush. A count by itself is normal. Watch the change between checks.", important: false),
            row(id: 14, name: "Media and Data Integrity Errors", kind: .preFail, raw: raw.mediaErrors, display: ByteFormat.decimal(raw.mediaErrors), current: raw.mediaErrors == 0 ? 100 : 1, threshold: 0, rating: raw.mediaErrors == 0 ? 100 : 1, status: raw.mediaErrors > 0 ? .failing : .ok, explanation: "Unrecoverable media errors. Any count is a pre-fail signal. Back up the drive.", important: true, health: true),
            row(id: 15, name: "Error Information Log Entries", kind: .preFail, raw: raw.errorLogEntries, display: ByteFormat.decimal(raw.errorLogEntries), current: raw.errorLogEntries == 0 ? 100 : 1, threshold: 0, rating: raw.errorLogEntries == 0 ? 100 : 1, status: raw.errorLogEntries == 0 ? .ok : .warning, explanation: "How many NVMe error-log records exist. macOS does not expose the log records themselves for Apple SSDs.", important: false, health: false),
            counter(id: 16, name: "Warning Composite Temperature Time", raw: UInt64(max(0, raw.warningTempMinutes)), display: durationDisplay(minutes: UInt64(max(0, raw.warningTempMinutes))), explanation: "Minutes the composite temperature has been above the warning threshold.", important: false),
            counter(id: 17, name: "Critical Composite Temperature Time", raw: UInt64(max(0, raw.criticalTempMinutes)), display: durationDisplay(minutes: UInt64(max(0, raw.criticalTempMinutes))), explanation: "Minutes the composite temperature has been above the critical threshold. A rising value means the drive ran hotter than its critical limit.", important: false)
        ]
    }

    public struct NVMeNumbers: Sendable {
        public var temperatureCelsius: Int
        public var availableSpare: Int
        public var spareThreshold: Int
        public var percentageUsed: Int
        public var criticalWarning: Int
        public var dataUnitsRead: UInt64
        public var dataUnitsWritten: UInt64
        public var hostReadCommands: UInt64
        public var hostWriteCommands: UInt64
        public var powerCycles: UInt64
        public var powerOnHours: UInt64
        public var unsafeShutdowns: UInt64
        public var mediaErrors: UInt64
        public var errorLogEntries: UInt64
        public var controllerBusyMinutes: UInt64
        public var warningTempMinutes: Int
        public var criticalTempMinutes: Int

        public init(
            temperatureCelsius: Int,
            availableSpare: Int,
            spareThreshold: Int,
            percentageUsed: Int,
            criticalWarning: Int,
            dataUnitsRead: UInt64,
            dataUnitsWritten: UInt64,
            hostReadCommands: UInt64 = 0,
            hostWriteCommands: UInt64 = 0,
            powerCycles: UInt64,
            powerOnHours: UInt64,
            unsafeShutdowns: UInt64,
            mediaErrors: UInt64,
            errorLogEntries: UInt64,
            controllerBusyMinutes: UInt64 = 0,
            warningTempMinutes: Int = 0,
            criticalTempMinutes: Int = 0
        ) {
            self.temperatureCelsius = temperatureCelsius
            self.availableSpare = availableSpare
            self.spareThreshold = spareThreshold
            self.percentageUsed = percentageUsed
            self.criticalWarning = criticalWarning
            self.dataUnitsRead = dataUnitsRead
            self.dataUnitsWritten = dataUnitsWritten
            self.hostReadCommands = hostReadCommands
            self.hostWriteCommands = hostWriteCommands
            self.powerCycles = powerCycles
            self.powerOnHours = powerOnHours
            self.unsafeShutdowns = unsafeShutdowns
            self.mediaErrors = mediaErrors
            self.errorLogEntries = errorLogEntries
            self.controllerBusyMinutes = controllerBusyMinutes
            self.warningTempMinutes = warningTempMinutes
            self.criticalTempMinutes = criticalTempMinutes
        }
    }

    /// NVMe reports no normalized temperature. The DriveDX-style mapping reads the
    /// Celsius value onto a 0–100 normalized scale (current = 100 − °C) with the
    /// warning point at 70 °C, so 42 °C shows normalized 58 against threshold 30 —
    /// 40% of the healthy range remaining.
    private static func temperatureRow(_ celsius: Int) -> HealthIndicator {
        let normalized = max(0, min(100, 100 - celsius))
        let threshold = 30
        let rating = min(100, max(0, Double(normalized - threshold) / Double(100 - threshold) * 100))
        return row(
            id: 2,
            name: "Composite Temperature",
            kind: .lifeSpan,
            raw: UInt64(max(0, celsius)),
            display: "\(celsius) °C",
            current: normalized,
            threshold: threshold,
            rating: rating,
            status: temperatureStatus(celsius),
            explanation: "NVMe composite temperature in Celsius. The normalized value treats 70 °C as the warning threshold; Apple SSDs usually stay well below it.",
            important: true,
            health: false
        )
    }

    /// A counter with no failure semantics: the row reads a full, healthy bar.
    private static func counter(id: Int, name: String, raw: UInt64, display: String, explanation: String, important: Bool) -> HealthIndicator {
        row(id: id, name: name, kind: .lifeSpan, raw: raw, display: display, current: 100, threshold: 0, rating: 100, status: .ok, explanation: explanation, important: important, health: false)
    }

    private static func row(
        id: Int,
        name: String,
        kind: IndicatorKind,
        raw: UInt64,
        display: String,
        current: Int?,
        threshold: Int?,
        rating: Double?,
        status: IndicatorStatus,
        explanation: String,
        important: Bool,
        health: Bool
    ) -> HealthIndicator {
        HealthIndicator(
            id: id,
            name: name,
            kind: kind,
            updateMode: .online,
            raw: raw,
            rawDisplay: display,
            current: current,
            worst: nil,
            threshold: threshold,
            rating: rating,
            status: status,
            explanation: explanation,
            isImportant: important,
            affectsPerformance: false,
            countsTowardHealth: health
        )
    }

    /// "583,746,515 (298.9 TB)" — the raw data-unit count plus the physical total.
    private static func dataUnitsDisplay(_ units: UInt64) -> String {
        let bytes: String
        if units > UInt64.max / dataUnitBytes {
            bytes = ByteFormat.decimal(units)
        } else {
            bytes = ByteFormat.bytes(units * dataUnitBytes)
        }
        return "\(ByteFormat.decimal(units)) (\(bytes))"
    }

    /// "0 (0 minutes)" for short durations, converted to hours beyond that.
    private static func durationDisplay(minutes: UInt64) -> String {
        if minutes < 120 {
            return "\(ByteFormat.decimal(minutes)) (\(ByteFormat.decimal(minutes)) minutes)"
        }
        return "\(ByteFormat.decimal(minutes)) (\(ByteFormat.decimal(minutes / 60)) hours)"
    }

    private static func spareHealth(spare: Int, threshold: Int) -> Double {
        if spare <= threshold { return 0 }
        let span = Double(max(100 - threshold, 1))
        return min(100, max(0, Double(spare - threshold) / span * 100))
    }

    private static func temperatureStatus(_ celsius: Int) -> IndicatorStatus {
        if celsius >= 85 { return .failing }
        if celsius >= 70 { return .warning }
        return .ok
    }

    private static func criticalText(_ bits: Int) -> String {
        if bits == 0 { return "No NVMe critical warning bits are set." }
        var parts: [String] = []
        if bits & 0x01 != 0 { parts.append("spare space is below the threshold") }
        if bits & 0x02 != 0 { parts.append("temperature is out of range") }
        if bits & 0x04 != 0 { parts.append("reliability is degraded") }
        if bits & 0x08 != 0 { parts.append("the drive is in read-only mode") }
        if bits & 0x10 != 0 { parts.append("backup capacitor failure") }
        return "Critical warning: " + parts.joined(separator: ", ") + "."
    }
}
