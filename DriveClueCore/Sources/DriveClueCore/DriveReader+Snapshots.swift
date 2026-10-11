import CSMART
import Foundation

// Turns the raw C-bridge output into DriveSnapshot values, one builder per transport.
extension DriveReader {
    static func ataSnapshot(
        bsd: String,
        volumes: [VolumeInfo],
        registryModel: String,
        registrySerial: String,
        registryFirmware: String,
        mediaSize: UInt64,
        block: Int,
        interconnect: String,
        location: String,
        ioErrors: Int?,
        removable: Bool,
        ejectable: Bool,
        checked: Date
    ) -> DriveSnapshot {
        var raw: DSATARaw = zero()
        let code = bsd.withCString { DSReadATA($0, &raw) }
        guard code == 0, raw.has_smart == 1 else {
            return failedSnapshot(
                bsd: bsd, volumes: volumes, transport: .ata,
                model: registryModel, serial: registrySerial, firmware: registryFirmware,
                capacity: mediaSize, block: block, interconnect: interconnect,
                location: location, ioErrors: ioErrors, removable: removable,
                ejectable: ejectable, checked: checked,
                reason: string(raw.error) ?? "ATA S.M.A.R.T. could not be read"
            )
        }
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
        guard !attributes.isEmpty else {
            return failedSnapshot(
                bsd: bsd, volumes: volumes, transport: .ata,
                model: registryModel, serial: registrySerial, firmware: registryFirmware,
                capacity: mediaSize, block: block, interconnect: interconnect,
                location: location, ioErrors: ioErrors, removable: removable,
                ejectable: ejectable, checked: checked,
                reason: "The drive returned no usable S.M.A.R.T. attributes"
            )
        }
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
        let written = attributes.first { $0.id == 241 }.map { min($0.raw, UInt64.max / UInt64(max(sectorSize, 1))) * UInt64(sectorSize) }
        let supportsSelfTest = identity?.supportsSelfTest ?? true
        let capacity: UInt64
        if let identity, identity.sectorCount > 0 {
            capacity = identity.sectorCount * UInt64(sectorSize)
        } else {
            capacity = mediaSize
        }
        var capabilities = [
            Capability(name: "Connection", value: connectionText(interconnect: interconnect, location: location, transport: "ATA")),
            Capability(name: "S.M.A.R.T.", value: identity?.supportsSMART == false ? "Not advertised" : "Supported"),
            Capability(name: "Self-test", value: supportsSelfTest ? "Short and full" : "Not advertised"),
            Capability(name: "TRIM", value: identity?.supportsTRIM == true ? "Supported" : "Not reported"),
            Capability(name: "Removable / Ejectable", value: "\(removable ? "Yes" : "No") / \(ejectable ? "Yes" : "No")")
        ]
        if let identity, identity.rotationRate > 1 {
            capabilities.append(Capability(name: "Rotation", value: "\(identity.rotationRate) rpm"))
        } else if isSSD {
            capabilities.append(Capability(name: "Media", value: "Solid state"))
        }
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
            capacityBytes: capacity,
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
            smartStatus: summary.status,
            issueCount: summary.issues,
            isSSD: isSSD,
            supportsSelfTest: supportsSelfTest,
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
            interconnect: interconnect,
            location: location
        )
    }

    static func nvmeSnapshot(
        bsd: String,
        volumes: [VolumeInfo],
        registryModel: String,
        registrySerial: String,
        registryFirmware: String,
        mediaSize: UInt64,
        block: Int,
        interconnect: String,
        location: String,
        ioErrors: Int?,
        removable: Bool,
        ejectable: Bool,
        checked: Date
    ) -> DriveSnapshot {
        var raw: DSNVMeRaw = zero()
        let code = bsd.withCString { DSReadNVMe($0, &raw) }
        guard code == 0 else {
            return failedSnapshot(
                bsd: bsd, volumes: volumes, transport: .nvme,
                model: registryModel, serial: registrySerial, firmware: registryFirmware,
                capacity: mediaSize, block: block, interconnect: interconnect,
                location: location, ioErrors: ioErrors, removable: removable,
                ejectable: ejectable, checked: checked,
                reason: string(raw.error) ?? "NVMe health data could not be read"
            )
        }
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
            hostReadCommands: raw.host_read_commands,
            hostWriteCommands: raw.host_write_commands,
            powerCycles: raw.power_cycles,
            powerOnHours: raw.power_on_hours,
            unsafeShutdowns: raw.unsafe_shutdowns,
            mediaErrors: raw.media_errors,
            errorLogEntries: raw.error_log_entries,
            controllerBusyMinutes: raw.controller_busy_time,
            warningTempMinutes: Int(raw.warning_temp_time),
            criticalTempMinutes: Int(raw.critical_temp_time)
        )
        let indicators = NVMeLog.indicators(raw: numbers)
        let summary = DriveScorer.summarize(indicators, isSSD: true)
        let lba = raw.lba_size == 0 ? (block == 0 ? 4096 : block) : Int(raw.lba_size)
        let bytesWritten = unitBytes(raw.data_units_written)
        let statistics = [
            StatSection(title: "General Statistics", entries: [
                StatEntry(name: "Power-on Hours", value: ByteFormat.decimal(raw.power_on_hours)),
                StatEntry(name: "Power Cycles", value: ByteFormat.decimal(raw.power_cycles)),
                StatEntry(name: "Data Read", value: ByteFormat.bytes(unitBytes(raw.data_units_read))),
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
        var capabilities = [
            Capability(name: "Connection", value: connectionText(interconnect: interconnect, location: location, transport: "NVMe")),
            Capability(name: "S.M.A.R.T.", value: "NVMe health log"),
            Capability(name: "Self-test", value: "Not available through macOS"),
            Capability(name: "PCI Vendor", value: raw.pci_vid == 0 ? "—" : String(format: "0x%04X", raw.pci_vid)),
            Capability(name: "Drive Type", value: "SSD"),
            Capability(name: "Logical Protocol", value: "NVM-Express (NVMe)"),
            Capability(name: "Removable / Ejectable", value: "\(removable ? "Yes" : "No") / \(ejectable ? "Yes" : "No")")
        ]
        if raw.has_identify == 1 {
            // MDTS is a power-of-two page count per the NVMe specification; 0 means
            // the controller sets no maximum.
            let transferSize = raw.max_data_transfer_size == 0 ? "Not limited" : "\(1 << Int(raw.max_data_transfer_size)) pages"
            let totalCapacity = raw.namespace_capacity_bytes > 0
                ? ByteFormat.bytes(raw.namespace_capacity_bytes)
                : (raw.namespace_bytes > 0 ? ByteFormat.bytes(raw.namespace_bytes) : "—")
            let unallocated = raw.namespace_capacity_bytes > raw.namespace_utilization_bytes
                ? ByteFormat.bytes(raw.namespace_capacity_bytes - raw.namespace_utilization_bytes)
                : "—"
            capabilities.append(contentsOf: [
                Capability(name: "Max Data Transfer Size", value: transferSize),
                Capability(name: "Volatile Write Cache", value: raw.volatile_write_cache & 0x01 == 1 ? "yes" : "no"),
                Capability(name: "Log Page Attributes", value: String(format: "0x%X", raw.log_page_attributes)),
                Capability(name: "Opt. Admin Command Support", value: String(format: "0x%X", raw.optional_admin_commands)),
                Capability(name: "Opt. NVM Command Support", value: String(format: "0x%X", raw.optional_nvm_commands)),
                Capability(name: "Format NVM Attributes", value: String(format: "0x%X", raw.format_nvm_attributes)),
                Capability(name: "Max Error Log Page Entries", value: "\(raw.error_log_page_entries)"),
                Capability(name: "Number of Power States", value: "\(raw.power_state_count)"),
                Capability(name: "Number of NVMe Namespaces", value: "\(raw.namespace_count)"),
                Capability(name: "Total NVMe Capacity", value: totalCapacity),
                Capability(name: "Unallocated NVMe Capacity", value: unallocated)
            ])
        }
        return DriveSnapshot(
            id: serial.nilIfEmpty ?? bsd,
            bsdName: bsd,
            volumes: volumes,
            transport: .nvme,
            model: model.isEmpty ? "NVMe SSD" : model,
            modelFamily: AttributeCatalog.family(model: model),
            serial: serial,
            firmware: firmware,
            capacityBytes: raw.namespace_bytes > 0 ? raw.namespace_bytes : mediaSize,
            sectorSize: lba,
            powerOnHours: Int(raw.power_on_hours),
            powerCycleCount: Int(raw.power_cycles),
            temperatureCelsius: celsius,
            recommendedTempMin: 5,
            recommendedTempMax: 65,
            temperatureLimitMin: 5,
            temperatureLimitMax: 70,
            indicators: indicators,
            overallHealth: summary.health,
            healthBand: summary.healthBand,
            performance: summary.performance,
            performanceBand: summary.performanceBand,
            ssdLife: summary.ssdLife,
            ssdLifeBand: summary.ssdLifeBand,
            smartStatus: summary.status,
            issueCount: summary.issues,
            isSSD: true,
            selfTestUnavailableReason: "macOS does not let apps start NVMe self-tests, including on Apple internal SSDs.",
            capabilities: capabilities,
            statistics: statistics,
            ioErrorCount: ioErrors,
            bytesWritten: bytesWritten,
            checkedAt: checked,
            interconnect: interconnect,
            location: location
        )
    }

    /// Preserve registry identity and connection context without treating a failed
    /// health-log read as a warning, a healthy drive, or a zero-valued measurement.
    static func failedSnapshot(
        bsd: String,
        volumes: [VolumeInfo],
        transport: DriveTransport,
        model: String,
        serial: String,
        firmware: String,
        capacity: UInt64,
        block: Int,
        interconnect: String,
        location: String,
        ioErrors: Int?,
        removable: Bool,
        ejectable: Bool,
        checked: Date,
        reason: String
    ) -> DriveSnapshot {
        DriveSnapshot(
            id: serial.nilIfEmpty ?? bsd,
            bsdName: bsd,
            volumes: volumes,
            transport: transport,
            model: model.isEmpty ? (transport == .ata ? "ATA drive" : "NVMe SSD") : model,
            modelFamily: AttributeCatalog.family(model: model),
            serial: serial,
            firmware: firmware,
            capacityBytes: capacity,
            sectorSize: block == 0 ? (transport == .ata ? 512 : 4096) : block,
            isSSD: transport == .nvme || model.uppercased().contains("SSD"),
            capabilities: [
                Capability(name: "Connection", value: connectionText(interconnect: interconnect, location: location, transport: transport == .ata ? "ATA" : "NVMe")),
                Capability(name: "Removable / Ejectable", value: "\(removable ? "Yes" : "No") / \(ejectable ? "Yes" : "No")")
            ],
            ioErrorCount: ioErrors,
            checkedAt: checked,
            readError: reason,
            interconnect: interconnect,
            location: location
        )
    }

    static func unavailable(
        bsd: String,
        volumes: [VolumeInfo],
        model: String,
        serial: String,
        firmware: String,
        capacity: UInt64,
        block: Int,
        interconnect: String,
        location: String,
        ioErrors: Int?,
        checked: Date,
        reason: String
    ) -> DriveSnapshot {
        DriveSnapshot(
            id: serial.nilIfEmpty ?? bsd,
            bsdName: bsd,
            volumes: volumes,
            model: model.isEmpty ? "Drive without S.M.A.R.T." : model,
            modelFamily: AttributeCatalog.family(model: model),
            serial: serial,
            firmware: firmware,
            capacityBytes: capacity,
            sectorSize: block == 0 ? 512 : block,
            capabilities: [Capability(name: "Connection", value: connectionText(interconnect: interconnect, location: location, transport: "Unknown"))],
            ioErrorCount: ioErrors,
            checkedAt: checked,
            readError: reason,
            interconnect: interconnect,
            location: location
        )
    }

    private static func connectionText(interconnect: String, location: String, transport: String) -> String {
        let parts = [location, interconnect, transport].filter { !$0.isEmpty }
        return parts.isEmpty ? transport : parts.joined(separator: " · ")
    }

    /// NVMe data units to bytes. Clamps so a truncated 128-bit counter can never
    /// overflow the multiplication; values that large are physically unreachable.
    private static func unitBytes(_ units: UInt64) -> UInt64 {
        min(units, UInt64.max / NVMeLog.dataUnitBytes) * NVMeLog.dataUnitBytes
    }

    private static func temperatureStats(_ sections: [StatSection]) -> (current: Int?, min: Int?, max: Int?, over: Int?, under: Int?) {
        let entries = sections.first { $0.title == "Temperature Statistics" }?.entries ?? []
        func value(_ name: String) -> Int? {
            guard let text = entries.first(where: { $0.name == name })?.value else { return nil }
            return Int(text.filter(\.isNumber))
        }
        return (value("Current Temperature"), value("Lowest Temperature"), value("Highest Temperature"), value("Time in Over-Temperature"), value("Time in Under-Temperature"))
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
