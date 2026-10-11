import Foundation

public enum DriveTransport: String, Codable, Sendable {
    case ata
    case nvme
    case unavailable
}

public enum IndicatorKind: String, Codable, Sendable {
    case preFail
    case lifeSpan
}

public enum UpdateMode: String, Codable, Sendable {
    case online
    case offline
    case unknown
}

public enum IndicatorStatus: String, Codable, Sendable, Comparable {
    case ok
    case warning
    case failing
    case failed

    public static func < (lhs: IndicatorStatus, rhs: IndicatorStatus) -> Bool {
        lhs.rank < rhs.rank
    }

    public var rank: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .failing: 2
        case .failed: 3
        }
    }

    public var title: String {
        switch self {
        case .ok: "OK"
        case .warning: "Warning"
        case .failing: "Failing"
        case .failed: "Failed"
        }
    }
}

public enum HealthBand: String, Codable, Sendable {
    case good
    case average
    case low
    case bad

    public var title: String {
        switch self {
        case .good: "GOOD"
        case .average: "AVERAGE"
        case .low: "LOW"
        case .bad: "BAD"
        }
    }

    public static func band(for rating: Double) -> HealthBand {
        if rating >= 80 { return .good }
        if rating >= 50 { return .average }
        if rating >= 20 { return .low }
        return .bad
    }
}

public enum DrivePage: String, Codable, Sendable, CaseIterable, Identifiable {
    case dashboard
    case usage
    case indicators
    case errors
    case statistics
    case selfTests

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .usage: "Storage Analyzer"
        case .indicators: "Health Indicators"
        case .errors: "Errors Log"
        case .statistics: "Device Statistics"
        case .selfTests: "Disk Speed Test"
        }
    }
}

public struct VolumeInfo: Codable, Sendable, Identifiable, Equatable {
    public var id: String { bsdName }
    public var name: String
    public var bsdName: String
    public var mountPath: String?
    public var role: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var purgeableBytes: UInt64

    public var isUserFacing: Bool {
        let hidden = ["Preboot", "Recovery", "VM", "Update", "Hardware", "XART", "iSCPreboot", "Baseband", "xART", "Container", "iBootSystemContainer"]
        if hidden.contains(role) || hidden.contains(name) { return false }
        if name.localizedCaseInsensitiveContains("Container") { return false }
        if name.hasPrefix("com.apple.") { return false }
        return true
    }

    public init(
        name: String,
        bsdName: String,
        mountPath: String?,
        role: String,
        totalBytes: UInt64,
        availableBytes: UInt64,
        purgeableBytes: UInt64
    ) {
        self.name = name
        self.bsdName = bsdName
        self.mountPath = mountPath
        self.role = role
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.purgeableBytes = purgeableBytes
    }
}

public struct HealthIndicator: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var name: String
    public var kind: IndicatorKind
    public var updateMode: UpdateMode
    public var raw: UInt64?
    public var rawDisplay: String
    public var current: Int?
    public var worst: Int?
    public var threshold: Int?
    public var rating: Double?
    public var status: IndicatorStatus
    public var explanation: String
    public var rawDelta: Int?
    public var isImportant: Bool
    public var affectsPerformance: Bool
    public var countsTowardHealth: Bool

    public init(
        id: Int,
        name: String,
        kind: IndicatorKind,
        updateMode: UpdateMode,
        raw: UInt64?,
        rawDisplay: String,
        current: Int?,
        worst: Int?,
        threshold: Int?,
        rating: Double?,
        status: IndicatorStatus,
        explanation: String,
        rawDelta: Int? = nil,
        isImportant: Bool,
        affectsPerformance: Bool,
        countsTowardHealth: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.updateMode = updateMode
        self.raw = raw
        self.rawDisplay = rawDisplay
        self.current = current
        self.worst = worst
        self.threshold = threshold
        self.rating = rating
        self.status = status
        self.explanation = explanation
        self.rawDelta = rawDelta
        self.isImportant = isImportant
        self.affectsPerformance = affectsPerformance
        self.countsTowardHealth = countsTowardHealth
    }
}

public struct DriveError: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var powerOnHours: Int?
    public var summary: String
    public var priorCommand: String
}

public struct StatEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var value: String
}

public struct StatSection: Codable, Sendable, Identifiable, Equatable {
    public var id: String { title }
    public var title: String
    public var entries: [StatEntry]
}

public struct SelfTestRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var powerOnHours: Int?
    public var testType: String
    public var progress: Int
    public var status: String
    public var failingLBA: String
}

public struct SelfTestProgress: Codable, Sendable, Equatable {
    public var percent: Int
    public var remainingMinutes: Int?
}

public struct Capability: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var value: String
}

public struct DriveEvent: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64
    public var takenAt: Date
    public var kind: String
    public var message: String
}

public struct DriveSnapshot: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var bsdName: String
    public var volumes: [VolumeInfo]
    public var transport: DriveTransport
    public var model: String
    public var modelFamily: String
    public var serial: String
    public var firmware: String
    public var wwn: String?
    public var capacityBytes: UInt64
    public var sectorSize: Int
    public var powerOnHours: Int?
    public var powerCycleCount: Int?
    public var temperatureCelsius: Int?
    public var temperatureMin: Int?
    public var temperatureMax: Int?
    public var recommendedTempMin: Int?
    public var recommendedTempMax: Int?
    public var temperatureLimitMin: Int?
    public var temperatureLimitMax: Int?
    public var overTemperatureMinutes: Int?
    public var underTemperatureMinutes: Int?
    public var indicators: [HealthIndicator]
    public var overallHealth: Double
    public var healthBand: HealthBand
    public var performance: Double?
    public var performanceBand: HealthBand?
    public var ssdLife: Double?
    public var ssdLifeBand: HealthBand?
    public var smartStatus: IndicatorStatus
    public var issueCount: Int
    public var isSSD: Bool
    public var supportsSelfTest: Bool
    public var selfTestUnavailableReason: String?
    public var capabilities: [Capability]
    public var errors: [DriveError]
    public var statistics: [StatSection]
    public var selfTests: [SelfTestRecord]
    public var selfTestProgress: SelfTestProgress?
    public var shortTestMinutes: Int?
    public var extendedTestMinutes: Int?
    public var ioErrorCount: Int?
    public var bytesWritten: UInt64?
    public var checkedAt: Date
    public var readError: String?
    public var interconnect: String
    public var location: String

    /// Defaults describe the least-healthy baseline so builders only pass what they know.
    public init(
        id: String,
        bsdName: String,
        volumes: [VolumeInfo] = [],
        transport: DriveTransport = .unavailable,
        model: String = "",
        modelFamily: String = "",
        serial: String = "",
        firmware: String = "",
        wwn: String? = nil,
        capacityBytes: UInt64 = 0,
        sectorSize: Int = 512,
        powerOnHours: Int? = nil,
        powerCycleCount: Int? = nil,
        temperatureCelsius: Int? = nil,
        temperatureMin: Int? = nil,
        temperatureMax: Int? = nil,
        recommendedTempMin: Int? = nil,
        recommendedTempMax: Int? = nil,
        temperatureLimitMin: Int? = nil,
        temperatureLimitMax: Int? = nil,
        overTemperatureMinutes: Int? = nil,
        underTemperatureMinutes: Int? = nil,
        indicators: [HealthIndicator] = [],
        overallHealth: Double = 0,
        healthBand: HealthBand = .bad,
        performance: Double? = nil,
        performanceBand: HealthBand? = nil,
        ssdLife: Double? = nil,
        ssdLifeBand: HealthBand? = nil,
        smartStatus: IndicatorStatus = .warning,
        issueCount: Int = 0,
        isSSD: Bool = false,
        supportsSelfTest: Bool = false,
        selfTestUnavailableReason: String? = nil,
        capabilities: [Capability] = [],
        errors: [DriveError] = [],
        statistics: [StatSection] = [],
        selfTests: [SelfTestRecord] = [],
        selfTestProgress: SelfTestProgress? = nil,
        shortTestMinutes: Int? = nil,
        extendedTestMinutes: Int? = nil,
        ioErrorCount: Int? = nil,
        bytesWritten: UInt64? = nil,
        checkedAt: Date,
        readError: String? = nil,
        interconnect: String = "",
        location: String = ""
    ) {
        self.id = id
        self.bsdName = bsdName
        self.volumes = volumes
        self.transport = transport
        self.model = model
        self.modelFamily = modelFamily
        self.serial = serial
        self.firmware = firmware
        self.wwn = wwn
        self.capacityBytes = capacityBytes
        self.sectorSize = sectorSize
        self.powerOnHours = powerOnHours
        self.powerCycleCount = powerCycleCount
        self.temperatureCelsius = temperatureCelsius
        self.temperatureMin = temperatureMin
        self.temperatureMax = temperatureMax
        self.recommendedTempMin = recommendedTempMin
        self.recommendedTempMax = recommendedTempMax
        self.temperatureLimitMin = temperatureLimitMin
        self.temperatureLimitMax = temperatureLimitMax
        self.overTemperatureMinutes = overTemperatureMinutes
        self.underTemperatureMinutes = underTemperatureMinutes
        self.indicators = indicators
        self.overallHealth = overallHealth
        self.healthBand = healthBand
        self.performance = performance
        self.performanceBand = performanceBand
        self.ssdLife = ssdLife
        self.ssdLifeBand = ssdLifeBand
        self.smartStatus = smartStatus
        self.issueCount = issueCount
        self.isSSD = isSSD
        self.supportsSelfTest = supportsSelfTest
        self.selfTestUnavailableReason = selfTestUnavailableReason
        self.capabilities = capabilities
        self.errors = errors
        self.statistics = statistics
        self.selfTests = selfTests
        self.selfTestProgress = selfTestProgress
        self.shortTestMinutes = shortTestMinutes
        self.extendedTestMinutes = extendedTestMinutes
        self.ioErrorCount = ioErrorCount
        self.bytesWritten = bytesWritten
        self.checkedAt = checkedAt
        self.readError = readError
        self.interconnect = interconnect
        self.location = location
    }

    /// A failed or unsupported S.M.A.R.T. read is not a health measurement.
    public var hasHealthReading: Bool { readError == nil && transport != .unavailable }
    public var presentableHealth: Double? { hasHealthReading ? overallHealth : nil }
    public var presentableHealthBand: HealthBand? { hasHealthReading ? healthBand : nil }

    public var displayName: String {
        let names = volumes.filter(\.isUserFacing).map(\.name)
        if names.isEmpty { return model.isEmpty ? bsdName : model }
        return names.joined(separator: ", ")
    }

    public var devicePath: String { "/dev/\(bsdName)" }

    public var preFailFailing: Int { indicators.filter { $0.kind == .preFail && $0.status == .failing }.count }
    public var lifeFailing: Int { indicators.filter { $0.kind == .lifeSpan && $0.status == .failing }.count }
    public var preFailFailed: Int { indicators.filter { $0.kind == .preFail && $0.status == .failed }.count }
    public var lifeFailed: Int { indicators.filter { $0.kind == .lifeSpan && $0.status == .failed }.count }
    public var preFailWarnings: Int { indicators.filter { $0.kind == .preFail && $0.status == .warning }.count }
    public var lifeWarnings: Int { indicators.filter { $0.kind == .lifeSpan && $0.status == .warning }.count }

    public var failedSelfTests: Int {
        selfTests.filter { record in
            let text = record.status.lowercased()
            return text.contains("fail") || (text.contains("error") && !text.contains("without"))
        }.count
    }

    public var verdict: String {
        if !hasHealthReading { return readError ?? "S.M.A.R.T. health data is unavailable." }
        switch smartStatus {
        case .failed: return "Failed. Back up and replace this drive."
        case .failing: return "Failing. Back up now and plan a replacement."
        case .warning: return issueCount == 1 ? "Healthy enough, with 1 warning." : "Healthy enough, with \(issueCount) warnings."
        case .ok: return issueCount == 0 ? "Healthy." : "OK, with \(issueCount) issue\(issueCount == 1 ? "" : "s")."
        }
    }

    public var statusLine: String {
        guard hasHealthReading else { return "Unavailable" }
        return switch smartStatus {
        case .ok: "OK"
        case .warning: "Warning"
        case .failing: "Failing"
        case .failed: "Failed"
        }
    }
}

public struct HistorySample: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64
    public var driveID: String
    public var takenAt: Date
    public var health: Double
    public var temperature: Double?
    public var ssdLife: Double?
    public var bytesWritten: Double?
}

/// One recorded value of a health indicator at a check time.
public struct IndicatorSample: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64
    public var takenAt: Date
    public var raw: Double?
    public var current: Int?
}

/// Change of a health indicator over a window of saved checks.
public struct IndicatorTrend: Codable, Sendable, Equatable {
    public var change: Int64
    public var spanDays: Double
    public var sampleCount: Int
}

public struct RawAttribute: Equatable, Sendable {
    public var id: Int
    public var flags: Int
    public var current: Int
    public var worst: Int
    public var threshold: Int
    public var raw: UInt64

    public init(id: Int, flags: Int, current: Int, worst: Int, threshold: Int, raw: UInt64) {
        self.id = id
        self.flags = flags
        self.current = current
        self.worst = worst
        self.threshold = threshold
        self.raw = raw
    }
}

public enum ByteFormat {
    public static func decimal(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        // Diagnostic values use the same comma-grouped notation as the reference app,
        // regardless of the Mac's current locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1000 && index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        if index == 0 { return "\(value) B" }
        return String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[index])
    }

    public static func durationHours(_ hours: Int) -> String {
        let days = hours / 24
        let remain = hours % 24
        if days == 0 { return "\(hours) hours" }
        return "\(hours) hours (\(days) days \(remain) hours)"
    }
}
