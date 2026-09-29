import Foundation

public struct AttributeInfo: Sendable {
    public var name: String
    public var explanation: String
    public var kind: IndicatorKind
    public var rawStyle: RawStyle
    public var isImportant: Bool
    public var affectsPerformance: Bool
    public var countsTowardHealth: Bool
    public var failingWhenRawPositive: Bool
    public var warningWhenRawPositive: Bool

    public enum RawStyle: Sendable {
        case decimal
        case hex
        case temperature
        case lba
        case hours
    }
}

public enum AttributeCatalog {
    public static func info(id: Int, model: String) -> AttributeInfo {
        if let override = modelOverrides(model: model)[id] {
            return override
        }
        return known[id] ?? AttributeInfo(
            name: "Vendor attribute",
            explanation: "The manufacturer did not publish what this counter means. Treat a rising raw value as a clue, not a verdict.",
            kind: .lifeSpan,
            rawStyle: .hex,
            isImportant: false,
            affectsPerformance: false,
            countsTowardHealth: false,
            failingWhenRawPositive: false,
            warningWhenRawPositive: false
        )
    }

    public static func family(model: String) -> String {
        let upper = model.uppercased()
        if upper.contains("APPLE") { return "Apple SSDs" }
        if upper.contains("SAMSUNG") { return "Samsung based SSDs" }
        if upper.contains("WDC") || upper.contains("WD ") || upper.contains("WESTERN DIGITAL") { return "Western Digital drives" }
        if upper.contains("SEAGATE") || upper.hasPrefix("ST") { return "Seagate drives" }
        if upper.contains("TOSHIBA") || upper.contains("KIOXIA") { return "Toshiba / Kioxia drives" }
        if upper.contains("INTEL") { return "Intel SSDs" }
        if upper.contains("CRUCIAL") || upper.contains("MICRON") { return "Crucial / Micron SSDs" }
        if upper.contains("KINGSTON") { return "Kingston SSDs" }
        if upper.contains("SANDISK") { return "SanDisk SSDs" }
        if upper.contains("NVME") || upper.contains("SSD") { return "Solid state drives" }
        return "Generic drives"
    }

    private static func modelOverrides(model: String) -> [Int: AttributeInfo] {
        let upper = model.uppercased()
        if upper.contains("SAMSUNG") {
            return [
                177: infoCopy(known[177], name: "Wear Leveling Count", important: true, health: true),
                179: infoCopy(known[179], name: "Used Reserved Block Count Total", important: true, health: true),
                241: infoCopy(known[241], name: "Total LBAs Written", important: true, health: false)
            ].compactMapValues { $0 }
        }
        return [:]
    }

    private static func infoCopy(_ base: AttributeInfo?, name: String, important: Bool, health: Bool) -> AttributeInfo? {
        guard var copy = base else { return nil }
        copy.name = name
        copy.isImportant = important
        copy.countsTowardHealth = health
        return copy
    }

    static let known: [Int: AttributeInfo] = [
        1: AttributeInfo(name: "Raw Read Error Rate", explanation: "How often the drive retries a read. A falling normalized value matters more than the raw number, which many vendors encode in a private format.", kind: .preFail, rawStyle: .hex, isImportant: false, affectsPerformance: true, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        2: AttributeInfo(name: "Throughput Performance", explanation: "A vendor score of how quickly the drive is moving data compared with its own design.", kind: .preFail, rawStyle: .decimal, isImportant: false, affectsPerformance: true, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        3: AttributeInfo(name: "Spin-Up Time", explanation: "How long a hard drive takes to reach operating speed. A large increase can mean a weak motor or power supply.", kind: .preFail, rawStyle: .decimal, isImportant: false, affectsPerformance: true, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        4: AttributeInfo(name: "Start Stop Count", explanation: "How many times the spindle has started and stopped.", kind: .lifeSpan, rawStyle: .decimal, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        5: AttributeInfo(name: "Reallocated Sector Count", explanation: "Sectors the drive has retired and replaced from spare area. Any non-zero count is a strong early sign of media trouble, even while the health bar still reads 100%.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        7: AttributeInfo(name: "Seek Error Rate", explanation: "How often the heads miss the requested track. Vendors encode the raw value differently, so use the normalized value.", kind: .preFail, rawStyle: .hex, isImportant: false, affectsPerformance: true, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        8: AttributeInfo(name: "Seek Time Performance", explanation: "A vendor score of average seek speed.", kind: .preFail, rawStyle: .decimal, isImportant: false, affectsPerformance: true, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        9: AttributeInfo(name: "Power-On Hours", explanation: "Hours the drive has been powered on since it was made.", kind: .lifeSpan, rawStyle: .hours, isImportant: true, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        10: AttributeInfo(name: "Spin Retry Count", explanation: "Times the spindle needed an extra try to reach speed.", kind: .preFail, rawStyle: .decimal, isImportant: false, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        11: AttributeInfo(name: "Calibration Retry Count", explanation: "Times calibration had to be repeated.", kind: .preFail, rawStyle: .decimal, isImportant: false, affectsPerformance: true, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        12: AttributeInfo(name: "Power Cycle Count", explanation: "How many times the drive has been powered on.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        170: AttributeInfo(name: "Reserved Block Count", explanation: "Spare blocks the SSD still has available.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        171: AttributeInfo(name: "Program Fail Count", explanation: "Times the SSD failed to program a NAND page.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        172: AttributeInfo(name: "Erase Fail Count", explanation: "Times the SSD failed to erase a NAND block.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        173: AttributeInfo(name: "Wear Leveling Count", explanation: "How evenly the SSD has spread writes across its flash.", kind: .lifeSpan, rawStyle: .decimal, isImportant: false, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        174: AttributeInfo(name: "Unexpected Power Loss Count", explanation: "Times power disappeared before the drive could flush its cache.", kind: .lifeSpan, rawStyle: .decimal, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        177: AttributeInfo(name: "Wear Leveling Count", explanation: "SSD wear-leveling health. The normalized value usually starts near 100 and falls as the flash wears.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        179: AttributeInfo(name: "Used Reserved Block Count Total", explanation: "Spare flash blocks already consumed. A rising count means the SSD is using its reserve.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        180: AttributeInfo(name: "Unused Reserved Block Count", explanation: "Spare flash blocks still unused.", kind: .preFail, rawStyle: .decimal, isImportant: false, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        181: AttributeInfo(name: "Program Fail Count Total", explanation: "Total NAND program failures.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        182: AttributeInfo(name: "Erase Fail Count Total", explanation: "Total NAND erase failures. Any count is a reason to watch the drive closely.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        183: AttributeInfo(name: "Runtime Bad Block", explanation: "Bad flash blocks found while the SSD was in use.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        184: AttributeInfo(name: "End-to-End Error", explanation: "Data path errors between the host and the media. A non-zero count is serious.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        187: AttributeInfo(name: "Reported Uncorrectable Errors", explanation: "Reads that failed even after the drive's own correction. A non-zero count means data could not be recovered.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        188: AttributeInfo(name: "Command Timeout", explanation: "Commands the drive did not finish in time. Often a cable, enclosure, or power problem rather than dead media.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: true),
        190: AttributeInfo(name: "Airflow Temperature", explanation: "Temperature reported by the drive's airflow sensor, in Celsius.", kind: .lifeSpan, rawStyle: .temperature, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        192: AttributeInfo(name: "Power-Off Retract Count", explanation: "Times the heads were parked because power was removed.", kind: .lifeSpan, rawStyle: .decimal, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        193: AttributeInfo(name: "Load Cycle Count", explanation: "Times the heads were loaded onto the platters. Very high counts on some laptop drives are a known wear issue.", kind: .lifeSpan, rawStyle: .decimal, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        194: AttributeInfo(name: "Temperature", explanation: "Current drive temperature in Celsius. The raw value may also pack lifetime minimum and maximum.", kind: .lifeSpan, rawStyle: .temperature, isImportant: true, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        195: AttributeInfo(name: "Hardware ECC Recovered", explanation: "Errors the drive corrected with its own ECC. A high raw value alone is not a failure.", kind: .lifeSpan, rawStyle: .hex, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        196: AttributeInfo(name: "Reallocation Event Count", explanation: "How many times the drive tried to remap sectors. Related to retired sectors.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        197: AttributeInfo(name: "Current Pending Sector Count", explanation: "Sectors waiting to be remapped because a read failed. Any pending sector is a pre-fail signal. Back up, then run a self-test.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        198: AttributeInfo(name: "Offline Uncorrectable Sector Count", explanation: "Sectors that stayed unreadable during an offline scan. Treat a non-zero count as failing media.", kind: .preFail, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: true, warningWhenRawPositive: false),
        199: AttributeInfo(name: "UDMA CRC Error Count", explanation: "Checksum errors on the connection. This usually means the cable, enclosure, or port, not the platters or NAND. Reseat or replace the cable.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: true),
        200: AttributeInfo(name: "Multi-Zone Error Rate", explanation: "A vendor write-error score.", kind: .lifeSpan, rawStyle: .hex, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        202: AttributeInfo(name: "Percent Lifetime Remaining", explanation: "Vendor estimate of SSD life still left. The normalized value is the percent remaining.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        231: AttributeInfo(name: "SSD Life Left", explanation: "Percent of SSD endurance remaining, as reported by the normalized value.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        232: AttributeInfo(name: "Available Reserved Space", explanation: "Spare area the SSD has left.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        233: AttributeInfo(name: "Media Wearout Indicator", explanation: "Normalized SSD life. 100 is fresh. It falls toward the threshold as the flash wears out.", kind: .lifeSpan, rawStyle: .decimal, isImportant: true, affectsPerformance: false, countsTowardHealth: true, failingWhenRawPositive: false, warningWhenRawPositive: false),
        241: AttributeInfo(name: "Total LBAs Written", explanation: "Logical blocks the host has written. Multiply by the sector size for bytes written.", kind: .lifeSpan, rawStyle: .lba, isImportant: true, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false),
        242: AttributeInfo(name: "Total LBAs Read", explanation: "Logical blocks the host has read.", kind: .lifeSpan, rawStyle: .lba, isImportant: false, affectsPerformance: false, countsTowardHealth: false, failingWhenRawPositive: false, warningWhenRawPositive: false)
    ]
}
