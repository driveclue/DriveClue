import CSMART
import Foundation

public enum DriveReader {
    public static func scan(ioErrorCount: (String) -> Int? = { _ in nil }) -> [DriveSnapshot] {
        let infos = enumerate()
        return infos.map { info in
            snapshot(info: info, ioErrors: ioErrorCount(cString(info.bsd_name)))
        }.sorted { $0.bsdName < $1.bsdName }
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

    private static func enumerate() -> [DSDiskInfo] {
        let capacity = Int(DS_MAX_DISKS)
        let pointer = UnsafeMutablePointer<DSDiskInfo>.allocate(capacity: capacity)
        defer { pointer.deallocate() }
        pointer.initialize(repeating: zero(), count: capacity)
        defer { pointer.deinitialize(count: capacity) }
        let count = Int(DSEnumerateDisks(pointer, Int32(capacity)))
        return (0..<count).map { pointer[$0] }
    }

    private static func snapshot(info: DSDiskInfo, ioErrors: Int?) -> DriveSnapshot {
        let bsd = cString(info.bsd_name)
        let volumes = enrich(volumes(from: info))
        let registryModel = string(info.registry_model) ?? ""
        let registrySerial = string(info.registry_serial) ?? ""
        let registryFirmware = string(info.registry_firmware) ?? ""
        let interconnect = string(info.interconnect) ?? ""
        let location = string(info.location) ?? ""
        let removable = info.removable != 0
        let ejectable = info.ejectable != 0
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
                ioErrors: ioErrors,
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
                removable: removable,
                ejectable: ejectable,
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
            removable: removable,
            ejectable: ejectable,
            checked: checked
        )
    }

    private static func unavailableReason(interconnect: String) -> String {
        let upper = interconnect.uppercased()
        if upper.contains("USB") || upper.contains("FIREWIRE") {
            return "macOS cannot read S.M.A.R.T. on USB or FireWire unless a SAT SMART driver is already installed. DriveClue does not install a kernel extension."
        }
        return "macOS did not expose S.M.A.R.T. for this disk."
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

    // MARK: C-bridge memory helpers, shared with DriveReader+Snapshots.swift

    static func cString<T>(_ value: T) -> String {
        string(value) ?? ""
    }

    static func string<T>(_ value: T) -> String? {
        withUnsafeBytes(of: value) { buffer in
            guard let base = buffer.bindMemory(to: CChar.self).baseAddress else { return nil }
            let text = String(cString: base).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    static func bytes<T>(_ value: T) -> Data {
        withUnsafeBytes(of: value) { Data($0) }
    }

    static func zero<T>() -> T {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.stride, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.stride)
        return pointer.load(as: T.self)
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
