import Foundation

public enum ATAParser {
    public static func attributes(smartData: Data, thresholds: Data?) -> [RawAttribute] {
        guard smartData.count >= 362 else { return [] }
        var results: [RawAttribute] = []
        let thresholdMap = thresholdTable(thresholds)
        for index in 0..<30 {
            let offset = 2 + index * 12
            guard offset + 12 <= smartData.count else { break }
            let id = Int(smartData[offset])
            if id == 0 { continue }
            let flags = Int(smartData[offset + 1]) | (Int(smartData[offset + 2]) << 8)
            let current = Int(smartData[offset + 3])
            let worst = Int(smartData[offset + 4])
            var raw: UInt64 = 0
            for byte in 0..<6 {
                raw |= UInt64(smartData[offset + 5 + byte]) << (8 * byte)
            }
            let threshold = thresholdMap[id] ?? 0
            results.append(RawAttribute(id: id, flags: flags, current: current, worst: worst, threshold: threshold, raw: raw))
        }
        return results
    }

    public static func identify(data: Data) -> ATAIdentity? {
        guard data.count >= 512 else { return nil }
        let model = ataString(data, word: 27, count: 20)
        let serial = ataString(data, word: 10, count: 10)
        let firmware = ataString(data, word: 23, count: 4)
        if model.isEmpty && serial.isEmpty { return nil }
        let rotation = word(data, 217)
        let lba48 = (word(data, 83) & (1 << 10)) != 0 || (word(data, 86) & (1 << 10)) != 0
        let sectors: UInt64
        if lba48 {
            sectors = UInt64(word(data, 100))
                | (UInt64(word(data, 101)) << 16)
                | (UInt64(word(data, 102)) << 32)
                | (UInt64(word(data, 103)) << 48)
        } else {
            sectors = UInt64(word(data, 60)) | (UInt64(word(data, 61)) << 16)
        }
        var sectorSize = 512
        let word106 = word(data, 106)
        if (word106 & (1 << 14)) != 0 && (word106 & (1 << 15)) == 0 && (word106 & (1 << 12)) != 0 {
            let logicalWords = UInt32(word(data, 117)) | (UInt32(word(data, 118)) << 16)
            if logicalWords >= 256 {
                sectorSize = Int(logicalWords * 2)
            }
        }
        let wwnSupported = (word(data, 84) & (1 << 8)) != 0 || (word(data, 87) & (1 << 8)) != 0
        var wwn: String?
        if wwnSupported {
            let value = (UInt64(word(data, 108)) << 48)
                | (UInt64(word(data, 109)) << 32)
                | (UInt64(word(data, 110)) << 16)
                | UInt64(word(data, 111))
            if value != 0 {
                wwn = String(format: "%016llX", value)
            }
        }
        let selfTest = (word(data, 84) & (1 << 1)) != 0 || (word(data, 87) & (1 << 1)) != 0
        let trim = (word(data, 169) & 1) != 0
        let smart = (word(data, 82) & 1) != 0
        return ATAIdentity(
            model: model,
            serial: serial,
            firmware: firmware,
            wwn: wwn,
            sectorCount: sectors,
            sectorSize: sectorSize,
            rotationRate: rotation,
            supportsSelfTest: selfTest,
            supportsTRIM: trim,
            supportsSMART: smart
        )
    }

    public static func errors(log: Data) -> [DriveError] {
        guard log.count >= 512 else { return [] }
        let index = Int(log[1])
        let count = Int(log[452]) | (Int(log[453]) << 8)
        if index == 0 || count == 0 { return [] }
        var records: [DriveError] = []
        let total = min(5, count)
        for slot in 0..<total {
            let order = (index - 1 - slot + 50) % 5
            let base = 2 + order * 90
            guard base + 90 <= log.count else { continue }
            let errorRegister = log[base + 61]
            let hours = Int(log[base + 88]) | (Int(log[base + 89]) << 8)
            let command = log[base + 5 * 12 + 7]
            let summary = describeError(errorRegister)
            if summary == "No error bits" && hours == 0 { continue }
            records.append(DriveError(
                id: records.count + 1,
                powerOnHours: hours,
                summary: summary,
                priorCommand: commandName(command)
            ))
        }
        return records
    }

    public static func selfTests(log: Data) -> [SelfTestRecord] {
        guard log.count >= 512 else { return [] }
        let revision = Int(log[0]) | (Int(log[1]) << 8)
        if revision == 0 { return [] }
        let latest = Int(log[508])
        var records: [SelfTestRecord] = []
        for step in 0..<21 {
            let descriptor = latest == 0 ? step : (latest - 1 - step + 21) % 21
            let base = 2 + descriptor * 24
            guard base + 24 <= log.count else { continue }
            let type = Int(log[base])
            let statusByte = Int(log[base + 1])
            let hours = Int(log[base + 2]) | (Int(log[base + 3]) << 8)
            if type == 0 && statusByte == 0 && hours == 0 { continue }
            let statusNibble = (statusByte >> 4) & 0x0F
            let remain = statusByte & 0x0F
            let lba = UInt32(log[base + 5])
                | (UInt32(log[base + 6]) << 8)
                | (UInt32(log[base + 7]) << 16)
                | (UInt32(log[base + 8]) << 24)
            let failed = statusNibble >= 3 && statusNibble != 0x0F && lba != 0
            records.append(SelfTestRecord(
                id: records.count + 1,
                powerOnHours: hours,
                testType: selfTestName(type),
                progress: statusNibble == 0x0F ? max(0, 100 - remain * 10) : 100,
                status: selfTestStatus(statusNibble),
                failingLBA: failed ? "\(lba)" : "—"
            ))
        }
        return records
    }

    public static func selfTestProgress(smartData: Data, shortMinutes: Int, extendedMinutes: Int) -> SelfTestProgress? {
        guard smartData.count > 363 else { return nil }
        let byte = Int(smartData[363])
        let status = (byte >> 4) & 0x0F
        guard status == 0x0F else { return nil }
        let remain = byte & 0x0F
        let percent = max(0, min(100, 100 - remain * 10))
        let minutes = extendedMinutes > shortMinutes ? extendedMinutes : shortMinutes
        return SelfTestProgress(percent: percent, remainingMinutes: minutes == 0 ? nil : minutes, isExtended: extendedMinutes > 2)
    }

    public static func pollingMinutes(smartData: Data) -> (short: Int, extended: Int) {
        guard smartData.count > 373 else { return (2, 0) }
        let short = Int(smartData[372])
        var extended = Int(smartData[373])
        if extended == 0xFF, smartData.count > 376 {
            extended = Int(smartData[375]) | (Int(smartData[376]) << 8)
        }
        return (max(short, 1), extended)
    }

    public static func statistics(log: Data) -> [StatSection] {
        guard log.count >= 512 else { return [] }
        var pages: [Int: Data] = [:]
        let pageCount = log.count / 512
        for index in 0..<pageCount {
            let slice = log.subdata(in: index * 512..<(index + 1) * 512)
            if slice.allSatisfy({ $0 == 0 }) { continue }
            let page = Int(slice[2])
            pages[page] = slice
        }
        if pages[0] != nil && pages.count == 1, let list = pages[0] {
            let listed = Int(list[8])
            if listed > 0 && listed < 64 {
                return [StatSection(title: "Supported Pages", entries: [
                    StatEntry(name: "Pages listed by the drive", value: (0..<listed).map { String(list[9 + $0]) }.joined(separator: ", "))
                ])]
            }
        }
        var sections: [StatSection] = []
        for page in pages.keys.sorted() where page != 0 {
            let entries = entries(page: page, data: pages[page]!)
            if !entries.isEmpty {
                sections.append(StatSection(title: pageTitle(page), entries: entries))
            }
        }
        return sections
    }

    public static func temperatureRange(attribute: RawAttribute?) -> (current: Int?, min: Int?, max: Int?) {
        guard let attribute else { return (nil, nil, nil) }
        let current = Int(attribute.raw & 0xFF)
        let min = Int((attribute.raw >> 16) & 0xFF)
        let max = Int((attribute.raw >> 32) & 0xFF)
        let saneCurrent = (0...125).contains(current) ? current : (attribute.current > 0 && attribute.current < 125 ? attribute.current : nil)
        return (
            saneCurrent,
            (0...125).contains(min) && min != 0 ? min : nil,
            (0...125).contains(max) && max != 0 ? max : nil
        )
    }

    private static func thresholdTable(_ data: Data?) -> [Int: Int] {
        guard let data, data.count >= 362 else { return [:] }
        var map: [Int: Int] = [:]
        for index in 0..<30 {
            let offset = 2 + index * 12
            let id = Int(data[offset])
            if id == 0 { continue }
            map[id] = Int(data[offset + 1])
        }
        return map
    }

    private static func word(_ data: Data, _ index: Int) -> UInt16 {
        let offset = index * 2
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func ataString(_ data: Data, word: Int, count: Int) -> String {
        var bytes: [UInt8] = []
        for index in 0..<count {
            let offset = (word + index) * 2
            guard offset + 1 < data.count else { break }
            bytes.append(data[offset + 1])
            bytes.append(data[offset])
        }
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describeError(_ register: UInt8) -> String {
        var parts: [String] = []
        if register & 0x40 != 0 { parts.append("UNC (uncorrectable data)") }
        if register & 0x10 != 0 { parts.append("IDNF (address not found)") }
        if register & 0x04 != 0 { parts.append("ABRT (command aborted)") }
        if register & 0x80 != 0 { parts.append("Interface CRC") }
        if register & 0x02 != 0 { parts.append("Track not found") }
        if register & 0x01 != 0 { parts.append("Address mark not found") }
        if parts.isEmpty { return register == 0 ? "No error bits" : String(format: "Error register 0x%02X", register) }
        return parts.joined(separator: ", ")
    }

    private static func commandName(_ code: UInt8) -> String {
        switch code {
        case 0x20, 0x21, 0x24: "Read sector (\(hex(code)))"
        case 0x25: "Read DMA extended (\(hex(code)))"
        case 0x60: "Read FPDMA queued (\(hex(code)))"
        case 0xC4, 0xC8, 0xC9: "Read DMA (\(hex(code)))"
        case 0x30, 0x31, 0x34: "Write sector (\(hex(code)))"
        case 0x35: "Write DMA extended (\(hex(code)))"
        case 0x61: "Write FPDMA queued (\(hex(code)))"
        case 0xCA, 0xCB: "Write DMA (\(hex(code)))"
        case 0xE7: "Flush cache"
        case 0xB0: "SMART (\(hex(code)))"
        case 0: "—"
        default: "Command \(hex(code))"
        }
    }

    private static func hex(_ code: UInt8) -> String { String(format: "0x%02X", code) }

    private static func selfTestName(_ code: Int) -> String {
        switch code {
        case 0x01: "Short offline"
        case 0x02: "Extended offline"
        case 0x03: "Conveyance offline"
        case 0x04: "Selective offline"
        case 0x81: "Short captive"
        case 0x82: "Extended captive"
        default: code == 0 ? "Unknown" : String(format: "Test 0x%02X", code)
        }
    }

    private static func selfTestStatus(_ nibble: Int) -> String {
        switch nibble {
        case 0x0: "Completed without error"
        case 0x1: "Aborted by host"
        case 0x2: "Interrupted by reset"
        case 0x3: "A fatal error stopped the test"
        case 0x4: "Completed with an unknown failure"
        case 0x5: "Completed with an electrical failure"
        case 0x6: "Completed with a servo failure"
        case 0x7: "Completed with a read failure"
        case 0xF: "In progress"
        default: "Status \(nibble)"
        }
    }

    private static func pageTitle(_ page: Int) -> String {
        switch page {
        case 1: "General Statistics"
        case 2: "Free Fall Statistics"
        case 3: "Rotating Media Statistics"
        case 4: "General Errors Statistics"
        case 5: "Temperature Statistics"
        case 6: "Transport Statistics"
        case 7: "Solid State Device Statistics"
        default: "Statistics Page \(page)"
        }
    }

    private static func entries(page: Int, data: Data) -> [StatEntry] {
        let names = pageNames[page] ?? [:]
        var results: [StatEntry] = []
        for offset in names.keys.sorted() {
            guard let value = statisticValue(data, offset: offset) else { continue }
            results.append(StatEntry(name: names[offset] ?? "Offset \(offset)", value: ByteFormat.decimal(value)))
        }
        return results
    }

    static func statisticValue(_ data: Data, offset: Int) -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        let flags = data[offset + 7]
        let supported = flags & 0x80 != 0
        let valid = flags & 0x40 != 0
        if !supported && !valid { return nil }
        var value: UInt64 = 0
        for byte in 0..<7 {
            value |= UInt64(data[offset + byte]) << (8 * byte)
        }
        return value
    }

    private static let pageNames: [Int: [Int: String]] = [
        1: [
            0x008: "Lifetime Power-on Resets",
            0x010: "Power-on Hours",
            0x018: "Logical Sectors Written",
            0x020: "Number of Write Commands",
            0x028: "Logical Sectors Read",
            0x030: "Number of Read Commands"
        ],
        2: [
            0x008: "Number of Free-Fall Events Detected",
            0x010: "Overlimit Shock Events"
        ],
        3: [
            0x008: "Spindle Motor Power-on Hours",
            0x010: "Head Flying Hours",
            0x018: "Head Load Events",
            0x020: "Number of Reallocated Logical Sectors",
            0x028: "Read Recovery Attempts",
            0x030: "Number of Mechanical Start Failures"
        ],
        4: [
            0x008: "Number of Reported Uncorrectable Errors",
            0x010: "Resets Between Command Acceptance and Completion"
        ],
        5: [
            0x008: "Current Temperature",
            0x010: "Average Short Term Temperature",
            0x018: "Average Long Term Temperature",
            0x020: "Highest Temperature",
            0x028: "Lowest Temperature",
            0x030: "Highest Average Short Term Temperature",
            0x038: "Lowest Average Short Term Temperature",
            0x040: "Time in Over-Temperature",
            0x048: "Specified Maximum Operating Temperature",
            0x050: "Time in Under-Temperature",
            0x058: "Specified Minimum Operating Temperature"
        ],
        6: [
            0x008: "Number of Hardware Resets",
            0x010: "Number of ASR Events",
            0x018: "Number of Interface CRC Errors"
        ],
        7: [
            0x008: "Percentage Used Endurance Indicator"
        ]
    ]
}

public struct ATAIdentity: Equatable, Sendable {
    public var model: String
    public var serial: String
    public var firmware: String
    public var wwn: String?
    public var sectorCount: UInt64
    public var sectorSize: Int
    public var rotationRate: UInt16
    public var supportsSelfTest: Bool
    public var supportsTRIM: Bool
    public var supportsSMART: Bool

    public var isSSD: Bool {
        rotationRate == 1 || model.uppercased().contains("SSD")
    }
}
