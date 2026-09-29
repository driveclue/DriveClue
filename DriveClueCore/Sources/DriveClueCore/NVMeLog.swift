import Foundation

public enum NVMeLog {
    public static let dataUnitBytes: UInt64 = 512_000

    public static func indicators(raw: NVMeNumbers) -> [HealthIndicator] {
        let life = max(0, min(100, 100 - Double(raw.percentageUsed)))
        let spareRating = spareHealth(spare: raw.availableSpare, threshold: raw.spareThreshold)
        let mediaStatus: IndicatorStatus = raw.mediaErrors > 0 ? .failing : .ok
        let warning = raw.criticalWarning
        return [
            row(id: 1, name: "Critical Warning", kind: .preFail, raw: UInt64(warning), display: String(format: "0x%02X", warning), current: warning == 0 ? 100 : 0, threshold: 1, rating: warning == 0 ? 100 : 0, status: warning == 0 ? .ok : .failed, explanation: criticalText(warning), important: true, health: true),
            row(id: 2, name: "Composite Temperature", kind: .lifeSpan, raw: UInt64(max(0, raw.temperatureCelsius)), display: "\(raw.temperatureCelsius) °C", current: 100, threshold: 0, rating: 100, status: temperatureStatus(raw.temperatureCelsius), explanation: "NVMe composite temperature. Apple SSDs usually stay well below 70 °C.", important: true, health: false),
            row(id: 3, name: "Available Spare", kind: .preFail, raw: UInt64(raw.availableSpare), display: "\(raw.availableSpare)%", current: raw.availableSpare, threshold: raw.spareThreshold, rating: spareRating, status: raw.availableSpare <= raw.spareThreshold ? .failed : (spareRating < 30 ? .warning : .ok), explanation: "Percent of spare flash still available. Failure starts at the spare threshold.", important: true, health: true),
            row(id: 5, name: "Percentage Used", kind: .lifeSpan, raw: UInt64(raw.percentageUsed), display: "\(raw.percentageUsed)%", current: Int(life), threshold: 0, rating: life, status: raw.percentageUsed >= 100 ? .failed : (raw.percentageUsed >= 90 ? .warning : .ok), explanation: "Vendor estimate of endurance already consumed. 100 means the rated life is used up. The drive can keep working after that.", important: true, health: true),
            row(id: 6, name: "Data Units Read", kind: .lifeSpan, raw: raw.dataUnitsRead, display: ByteFormat.bytes(raw.dataUnitsRead * dataUnitBytes), current: nil, threshold: nil, rating: nil, status: .ok, explanation: "Host data read. Each NVMe data unit is 512,000 bytes.", important: false, health: false),
            row(id: 7, name: "Data Units Written", kind: .lifeSpan, raw: raw.dataUnitsWritten, display: ByteFormat.bytes(raw.dataUnitsWritten * dataUnitBytes), current: nil, threshold: nil, rating: nil, status: .ok, explanation: "Host data written. Each NVMe data unit is 512,000 bytes.", important: true, health: false),
            row(id: 8, name: "Power On Hours", kind: .lifeSpan, raw: raw.powerOnHours, display: ByteFormat.durationHours(Int(min(raw.powerOnHours, UInt64(Int.max)))), current: nil, threshold: nil, rating: nil, status: .ok, explanation: "Hours this SSD has been powered on.", important: true, health: false),
            row(id: 9, name: "Power Cycles", kind: .lifeSpan, raw: raw.powerCycles, display: ByteFormat.decimal(raw.powerCycles), current: nil, threshold: nil, rating: nil, status: .ok, explanation: "Times the SSD has powered on.", important: false, health: false),
            row(id: 10, name: "Unsafe Shutdowns", kind: .lifeSpan, raw: raw.unsafeShutdowns, display: ByteFormat.decimal(raw.unsafeShutdowns), current: nil, threshold: nil, rating: nil, status: .ok, explanation: "Shutdowns that skipped a clean cache flush. A count by itself is normal. Watch the change between checks.", important: false, health: false),
            row(id: 11, name: "Media and Data Integrity Errors", kind: .preFail, raw: raw.mediaErrors, display: ByteFormat.decimal(raw.mediaErrors), current: raw.mediaErrors == 0 ? 100 : 1, threshold: 0, rating: raw.mediaErrors == 0 ? 100 : 1, status: mediaStatus, explanation: "Unrecoverable media errors. Any count is a pre-fail signal. Back up the drive.", important: true, health: true),
            row(id: 12, name: "Error Information Log Entries", kind: .lifeSpan, raw: raw.errorLogEntries, display: ByteFormat.decimal(raw.errorLogEntries), current: nil, threshold: nil, rating: nil, status: .ok, explanation: "How many NVMe error-log records exist. macOS does not expose the log records themselves for Apple SSDs.", important: false, health: false)
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
        public var powerCycles: UInt64
        public var powerOnHours: UInt64
        public var unsafeShutdowns: UInt64
        public var mediaErrors: UInt64
        public var errorLogEntries: UInt64

        public init(temperatureCelsius: Int, availableSpare: Int, spareThreshold: Int, percentageUsed: Int, criticalWarning: Int, dataUnitsRead: UInt64, dataUnitsWritten: UInt64, powerCycles: UInt64, powerOnHours: UInt64, unsafeShutdowns: UInt64, mediaErrors: UInt64, errorLogEntries: UInt64) {
            self.temperatureCelsius = temperatureCelsius
            self.availableSpare = availableSpare
            self.spareThreshold = spareThreshold
            self.percentageUsed = percentageUsed
            self.criticalWarning = criticalWarning
            self.dataUnitsRead = dataUnitsRead
            self.dataUnitsWritten = dataUnitsWritten
            self.powerCycles = powerCycles
            self.powerOnHours = powerOnHours
            self.unsafeShutdowns = unsafeShutdowns
            self.mediaErrors = mediaErrors
            self.errorLogEntries = errorLogEntries
        }
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
            rawIsApproximate: false,
            current: current,
            worst: current,
            threshold: threshold,
            rating: rating,
            status: status,
            explanation: explanation,
            isImportant: important,
            affectsPerformance: false,
            countsTowardHealth: health
        )
    }
}
