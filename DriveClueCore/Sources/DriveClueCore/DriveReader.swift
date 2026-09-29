import CSMART
import Foundation

public enum DriveReader {
    public static func scan(ioErrorCount: (String) -> Int = { _ in 0 }) -> [DriveSnapshot] {
        let infos = enumerate()
        return infos.map { info in
            snapshot(info: info, ioErrors: ioErrorCount(cString(info.bsd_name)))
        }.sorted { $0.bsdName < $1.bsdName }
    }

    public static func read(bsdName: String) -> DriveSnapshot? {
        enumerate().first { cString($0.bsd_name) == bsdName }.map { snapshot(info: $0, ioErrors: 0) }
    }

    private static func enumerate() -> [DSDiskInfo] {
        let capacity = Int(DS_MAX_DISKS)
        let pointer = UnsafeMutablePointer<DSDiskInfo>.allocate(capacity: capacity)
        defer { pointer.deallocate() }
        pointer.initialize(repeating: blankDisk(), count: capacity)
        defer { pointer.deinitialize(count: capacity) }
        let count = Int(DSEnumerateDisks(pointer, Int32(capacity)))
        return (0..<count).map { pointer[$0] }
    }

    private static func blankDisk() -> DSDiskInfo {
        zero()
    }

    public static func startSelfTest(bsdName: String, extended: Bool) -> String? {
        var error = Array(repeating: CChar(0), count: 256)
        let code = DSStartATASelfTest(bsdName, extended ? 1 : 0, &error, 256)
        if code == 0 { return nil }
        return string(error) ?? "The self-test did not start."
    }

    public static func abortSelfTest(bsdName: String) -> String? {
        var error = Array(repeating: CChar(0), count: 256)
        let code = DSAbortATASelfTest(bsdName, &error, 256)
        if code == 0 { return nil }
        return string(error) ?? "The self-test could not be cancelled."
    }

    private static func snapshot(info: DSDiskInfo, ioErrors: Int) -> DriveSnapshot {
        let bsd = cString(info.bsd_name)
        var volumes = volumes(from: info)
        volumes = enrich(volumes)
        let registryModel = string(info.registry_model) ?? ""
        let registrySerial = string(info.registry_serial) ?? ""
        let registryFirmware = string(info.registry_firmware) ?? ""
        let interconnect = string(info.interconnect) ?? ""
        let location = string(info.location) ?? ""
        let checked = Date()

        if info.smart_capable == 0 {
            return unavailable(
                bsd: bsd,
                volumes: volumes,
                model: registryModel,
                serial: registrySerial,
                firmware: registryFirmware,
                capacity: info.media_size,
                block: Int(info.block_size),
                interconnect: interconnect,
                location: location,
                checked: checked,
                reason: unavailableReason(interconnect: interconnect)
            )
        }

        if info.transport == 2 {
            return nvmeSnapshot(
                bsd: bsd,
                volumes: volumes,
                registryModel: registryModel,
                registrySerial: registrySerial,
                registryFirmware: registryFirmware,
                mediaSize: info.media_size,
                block: Int(info.block_size),
                interconnect: interconnect,
                location: location,
                ioErrors: ioErrors,
                checked: checked
            )
        }
        return ataSnapshot(
            bsd: bsd,
            volumes: volumes,
            registryModel: registryModel,
            registrySerial: registrySerial,
            registryFirmware: registryFirmware,
            mediaSize: info.media_size,
            block: Int(info.block_size),
            interconnect: interconnect,
            location: location,
            ioErrors: ioErrors,
            checked: checked
        )
    }

    private static func ataSnapshot(
        bsd: String,
        volumes: [VolumeInfo],
        registryModel: String,
        registrySerial: String,
        registryFirmware: String,
        mediaSize: UInt64,
        block: Int,
        interconnect: String,
        location: String,
        ioErrors: Int,
        checked: Date
    ) -> DriveSnapshot {
        var raw = blankATA()
        let code = bsd.withCString { DSReadATA($0, &raw) }
        let smart = bytes(raw.smart_data)
        let thresholds = raw.has_thresholds == 1 ? bytes(raw.thresholds) : nil
        let identifyData = raw.has_identify == 1 ? bytes(raw.identify) : nil
        let identity = identifyData.flatMap(ATAParser.identify)
        let model = identity?.model.nilIfEmpty ?? registryModel
        let serial = identity?.serial.nilIfEmpty ?? registrySerial
        let firmware = identity?.firmware.nilIfEmpty ?? registryFirmware
        let sectorSize = identity?.sectorSize ?? (block == 0 ? 512 : block)
        let isSSD = identity?.isSSD ?? model.uppercased().contains("SSD")
        let attributes = ATAParser.attributes(smartData: smart, thresholds: thresholds)
        let indicators = attributes.map { DriveScorer.score(attribute: $0, model: model, isSSD: isSSD, sectorSize: sectorSize) }
        let summary = DriveScorer.summarize(indicators, isSSD: isSSD)
        let hoursAttr = attributes.first { $0.id == 9 }
        let cyclesAttr = attributes.first { $0.id == 12 }
        let tempAttr = attributes.first { $0.id == 194 } ?? attributes.first { $0.id == 190 }
        let temps = ATAParser.temperatureRange(attribute: tempAttr)
        let polls = ATAParser.pollingMinutes(smartData: smart)
        let devstat = bytes(raw.devstat).prefix(Int(raw.devstat_bytes))
        let stats = raw.devstat_bytes > 0 ? ATAParser.statistics(log: Data(devstat)) : []
        let tempStats = temperatureStats(stats)
        let written = attributes.first { $0.id == 241 }.map { $0.raw * UInt64(sectorSize) }
        let supportsSelfTest = identity?.supportsSelfTest ?? true
        var capabilities = [
            Capability(name: "Connection", value: connectionText(interconnect: interconnect, location: location, transport: "ATA")),
            Capability(name: "S.M.A.R.T.", value: identity?.supportsSMART == false ? "Not advertised" : "Supported"),
            Capability(name: "Self-test", value: supportsSelfTest ? "Short and full" : "Not advertised"),
            Capability(name: "TRIM", value: identity?.supportsTRIM == true ? "Supported" : "Not reported")
        ]
        if let identity, identity.rotationRate > 1 {
            capabilities.append(Capability(name: "Rotation", value: "\(identity.rotationRate) rpm"))
        } else if isSSD {
            capabilities.append(Capability(name: "Media", value: "Solid state"))
        }
        let readError = code == 0 ? nil : (string(raw.error) ?? "ATA S.M.A.R.T. could not be read")
        return DriveSnapshot(
            id: serial.nilIfEmpty ?? bsd,
            bsdName: bsd,
            volumes: volumes,
            transport: .ata,
            model: model.isEmpty ? "ATA drive" : model,
            modelFamily: AttributeCatalog.family(model: model),
            serial: serial,
            firmware: firmware,
            wwn: identity?.wwn,
            capacityBytes: identity?.sectorCount ?? 0 > 0 ? (identity!.sectorCount * UInt64(sectorSize)) : mediaSize,
            sectorSize: sectorSize,
            powerOnHours: hoursAttr.map { Int($0.raw & 0xFFFFFFFF) },
            powerCycleCount: cyclesAttr.map { Int($0.raw & 0xFFFFFFFF) },
            temperatureCelsius: temps.current ?? tempStats.current,
            temperatureMin: temps.min ?? tempStats.min,
            temperatureMax: temps.max ?? tempStats.max,
            recommendedTempMin: isSSD ? 0 : 5,
            recommendedTempMax: isSSD ? 70 : 50,
            overTemperatureMinutes: tempStats.over,
            underTemperatureMinutes: tempStats.under,
            indicators: indicators,
            overallHealth: summary.health,
            healthBand: summary.healthBand,
            performance: summary.performance,
            performanceBand: summary.performanceBand,
            ssdLife: summary.ssdLife,
            ssdLifeBand: summary.ssdLifeBand,
            smartStatus: readError == nil ? summary.status : .warning,
            issueCount: summary.issues,
            isSSD: isSSD,
            supportsSelfTest: supportsSelfTest && readError == nil,
            selfTestUnavailableReason: supportsSelfTest ? nil : "This drive does not advertise self-tests.",
            capabilities: capabilities,
            errors: raw.has_error_log == 1 ? ATAParser.errors(log: bytes(raw.error_log)) : [],
            statistics: stats,
            selfTests: raw.has_selftest_log == 1 ? ATAParser.selfTests(log: bytes(raw.selftest_log)) : [],
            selfTestProgress: ATAParser.selfTestProgress(smartData: smart, shortMinutes: polls.short, extendedMinutes: polls.extended),
            shortTestMinutes: polls.short,
            extendedTestMinutes: polls.extended == 0 ? nil : polls.extended,
            ioErrorCount: ioErrors,
            bytesWritten: written,
            checkedAt: checked,
            readError: readError,
            interconnect: interconnect,
            location: location
        )
    }

    private static func nvmeSnapshot(
        bsd: String,
        volumes: [VolumeInfo],
        registryModel: String,
        registrySerial: String,
        registryFirmware: String,
        mediaSize: UInt64,
        block: Int,
        interconnect: String,
        location: String,
        ioErrors: Int,
        checked: Date
    ) -> DriveSnapshot {
        var raw = blankNVMe()
        let code = bsd.withCString { DSReadNVMe($0, &raw) }
        let model = string(raw.model).nilIfEmpty ?? registryModel
        let serial = string(raw.serial).nilIfEmpty ?? registrySerial
        let firmware = string(raw.firmware).nilIfEmpty ?? registryFirmware
        let celsius = Int(raw.temperature_k) > 200 ? Int(raw.temperature_k) - 273 : Int(raw.temperature_k)
        let numbers = NVMeLog.NVMeNumbers(
            temperatureCelsius: celsius,
            availableSpare: Int(raw.available_spare),
            spareThreshold: Int(raw.spare_threshold),
            percentageUsed: Int(raw.percentage_used),
            criticalWarning: Int(raw.critical_warning),
            dataUnitsRead: raw.data_units_read,
            dataUnitsWritten: raw.data_units_written,
            powerCycles: raw.power_cycles,
            powerOnHours: raw.power_on_hours,
            unsafeShutdowns: raw.unsafe_shutdowns,
            mediaErrors: raw.media_errors,
            errorLogEntries: raw.error_log_entries
        )
        let indicators = code == 0 ? NVMeLog.indicators(raw: numbers) : []
        let summary = DriveScorer.summarize(indicators, isSSD: true)
        let readError = code == 0 ? nil : (string(raw.error) ?? "NVMe health data could not be read")
        let lba = raw.lba_size == 0 ? (block == 0 ? 4096 : block) : Int(raw.lba_size)
        let bytesWritten = raw.data_units_written * NVMeLog.dataUnitBytes
        var statistics = [
            StatSection(title: "General Statistics", entries: [
                StatEntry(name: "Power-on Hours", value: ByteFormat.decimal(raw.power_on_hours)),
                StatEntry(name: "Power Cycles", value: ByteFormat.decimal(raw.power_cycles)),
                StatEntry(name: "Data Read", value: ByteFormat.bytes(raw.data_units_read * NVMeLog.dataUnitBytes)),
                StatEntry(name: "Data Written", value: ByteFormat.bytes(bytesWritten)),
                StatEntry(name: "Read Commands", value: ByteFormat.decimal(raw.host_read_commands)),
                StatEntry(name: "Write Commands", value: ByteFormat.decimal(raw.host_write_commands))
            ]),
            StatSection(title: "Solid State Device Statistics", entries: [
                StatEntry(name: "Percentage Used Endurance Indicator", value: "\(raw.percentage_used)%"),
                StatEntry(name: "Available Spare", value: "\(raw.available_spare)%"),
                StatEntry(name: "Unsafe Shutdowns", value: ByteFormat.decimal(raw.unsafe_shutdowns)),
                StatEntry(name: "Media Errors", value: ByteFormat.decimal(raw.media_errors))
            ]),
            StatSection(title: "Temperature Statistics", entries: [
                StatEntry(name: "Current Temperature", value: "\(celsius) °C")
            ])
        ]
        if code != 0 { statistics = [] }
        return DriveSnapshot(
            id: serial.nilIfEmpty ?? bsd,
            bsdName: bsd,
            volumes: volumes,
            transport: .nvme,
            model: model.isEmpty ? "NVMe SSD" : model,
            modelFamily: AttributeCatalog.family(model: model),
            serial: serial,
            firmware: firmware,
            wwn: nil,
            capacityBytes: raw.namespace_bytes > 0 ? raw.namespace_bytes : mediaSize,
            sectorSize: lba,
            powerOnHours: Int(raw.power_on_hours),
            powerCycleCount: Int(raw.power_cycles),
            temperatureCelsius: celsius,
            temperatureMin: nil,
            temperatureMax: nil,
            recommendedTempMin: 0,
            recommendedTempMax: 70,
            overTemperatureMinutes: nil,
            underTemperatureMinutes: nil,
            indicators: indicators,
            overallHealth: summary.health,
            healthBand: summary.healthBand,
            performance: summary.performance,
            performanceBand: summary.performanceBand,
            ssdLife: summary.ssdLife,
            ssdLifeBand: summary.ssdLifeBand,
            smartStatus: readError == nil ? summary.status : .warning,
            issueCount: summary.issues,
            isSSD: true,
            supportsSelfTest: false,
            selfTestUnavailableReason: "macOS does not let apps start NVMe self-tests, including on Apple internal SSDs.",
            capabilities: [
                Capability(name: "Connection", value: connectionText(interconnect: interconnect, location: location, transport: "NVMe")),
                Capability(name: "S.M.A.R.T.", value: "NVMe health log"),
                Capability(name: "Self-test", value: "Not available through macOS"),
                Capability(name: "PCI Vendor", value: raw.pci_vid == 0 ? "—" : String(format: "0x%04X", raw.pci_vid))
            ],
            errors: [],
            statistics: statistics,
            selfTests: [],
            selfTestProgress: nil,
            shortTestMinutes: nil,
            extendedTestMinutes: nil,
            ioErrorCount: ioErrors,
            bytesWritten: bytesWritten,
            checkedAt: checked,
            readError: readError,
            interconnect: interconnect,
            location: location
        )
    }

    private static func unavailable(
        bsd: String,
        volumes: [VolumeInfo],
        model: String,
        serial: String,
        firmware: String,
        capacity: UInt64,
        block: Int,
        interconnect: String,
        location: String,
        checked: Date,
        reason: String
    ) -> DriveSnapshot {
        DriveSnapshot(
            id: serial.nilIfEmpty ?? bsd,
            bsdName: bsd,
            volumes: volumes,
            transport: .unavailable,
            model: model.isEmpty ? "Drive without S.M.A.R.T." : model,
            modelFamily: AttributeCatalog.family(model: model),
            serial: serial,
            firmware: firmware,
            wwn: nil,
            capacityBytes: capacity,
            sectorSize: block == 0 ? 512 : block,
            powerOnHours: nil,
            powerCycleCount: nil,
            temperatureCelsius: nil,
            temperatureMin: nil,
            temperatureMax: nil,
            recommendedTempMin: nil,
            recommendedTempMax: nil,
            overTemperatureMinutes: nil,
            underTemperatureMinutes: nil,
            indicators: [],
            overallHealth: 0,
            healthBand: .bad,
            performance: nil,
            performanceBand: nil,
            ssdLife: nil,
            ssdLifeBand: nil,
            smartStatus: .warning,
            issueCount: 1,
            isSSD: false,
            supportsSelfTest: false,
            selfTestUnavailableReason: reason,
            capabilities: [Capability(name: "Connection", value: connectionText(interconnect: interconnect, location: location, transport: "Unknown"))],
            errors: [],
            statistics: [],
            selfTests: [],
            selfTestProgress: nil,
            shortTestMinutes: nil,
            extendedTestMinutes: nil,
            ioErrorCount: 0,
            bytesWritten: nil,
            checkedAt: checked,
            readError: reason,
            interconnect: interconnect,
            location: location
        )
    }

    private static func unavailableReason(interconnect: String) -> String {
        let upper = interconnect.uppercased()
        if upper.contains("USB") || upper.contains("FIREWIRE") {
            return "macOS cannot read S.M.A.R.T. on USB or FireWire unless a SAT SMART driver is already installed. DriveClue does not install a kernel extension."
        }
        return "macOS did not expose S.M.A.R.T. for this disk."
    }

    private static func connectionText(interconnect: String, location: String, transport: String) -> String {
        let parts = [location, interconnect, transport].filter { !$0.isEmpty }
        return parts.isEmpty ? transport : parts.joined(separator: " · ")
    }

    private static func temperatureStats(_ sections: [StatSection]) -> (current: Int?, min: Int?, max: Int?, over: Int?, under: Int?) {
        let entries = sections.first { $0.title == "Temperature Statistics" }?.entries ?? []
        func value(_ name: String) -> Int? {
            guard let text = entries.first(where: { $0.name == name })?.value else { return nil }
            return Int(text.filter(\.isNumber))
        }
        return (value("Current Temperature"), value("Lowest Temperature"), value("Highest Temperature"), value("Time in Over-Temperature"), value("Time in Under-Temperature"))
    }

    private static func volumes(from info: DSDiskInfo) -> [VolumeInfo] {
        let count = Int(info.volume_count)
        guard count > 0 else { return [] }
        return withUnsafeBytes(of: info.volumes) { buffer in
            let bound = buffer.bindMemory(to: DSVolumeInfo.self)
            return (0..<min(count, bound.count)).map { index in
                let volume = bound[index]
                let mount = string(volume.mount_path)
                return VolumeInfo(
                    name: string(volume.name) ?? "Volume",
                    bsdName: cString(volume.bsd_name),
                    mountPath: mount?.nilIfEmpty,
                    role: string(volume.role) ?? "",
                    totalBytes: volume.size_bytes,
                    availableBytes: 0,
                    purgeableBytes: 0
                )
            }
        }
    }

    private static func enrich(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        volumes.map { volume in
            guard let mount = volume.mountPath, !mount.isEmpty else { return volume }
            var copy = volume
            let url = URL(fileURLWithPath: mount)
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            if let values = try? url.resourceValues(forKeys: keys) {
                if let total = values.volumeTotalCapacity { copy.totalBytes = UInt64(total) }
                let legacy = Int64(values.volumeAvailableCapacity ?? 0)
                let important = values.volumeAvailableCapacityForImportantUsage ?? legacy
                copy.availableBytes = UInt64(max(important, 0))
                copy.purgeableBytes = UInt64(max(0, important - legacy))
            }
            return copy
        }
    }

    private static func cString<T>(_ value: T) -> String {
        string(value) ?? ""
    }

    private static func string<T>(_ value: T) -> String? {
        withUnsafeBytes(of: value) { buffer in
            guard let base = buffer.bindMemory(to: CChar.self).baseAddress else { return nil }
            let text = String(cString: base).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private static func bytes<T>(_ value: T) -> Data {
        withUnsafeBytes(of: value) { Data($0) }
    }

    private static func blankATA() -> DSATARaw { zero() }

    private static func blankNVMe() -> DSNVMeRaw { zero() }

    private static func zero<T>() -> T {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.stride, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.stride)
        return pointer.load(as: T.self)
    }
}

private extension DriveTransport {
    init(rawTransport: Int, capable: Bool) {
        if !capable {
            self = .unavailable
            return
        }
        switch rawTransport {
        case 1: self = .ata
        case 2: self = .nvme
        default: self = .unavailable
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
