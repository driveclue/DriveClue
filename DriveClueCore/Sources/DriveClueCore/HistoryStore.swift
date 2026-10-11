import Foundation
import SQLite3

/// SQLite-backed history of drive samples, per-indicator latest values, and events.
/// All public methods serialize access through `queue`; private helpers run on that queue
/// and must only be called from inside a `queue.sync` block.
public final class HistoryStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "DriveClue.history")

    public init(url: URL? = nil) {
        let file = url ?? HistoryStore.defaultURL
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(file.path, &database) != SQLITE_OK {
            database = nil
            return
        }
        execute("CREATE TABLE IF NOT EXISTS samples (id INTEGER PRIMARY KEY AUTOINCREMENT, drive_id TEXT NOT NULL, taken_at REAL NOT NULL, health REAL, temperature REAL, ssd_life REAL, bytes_written REAL, status TEXT)")
        execute("CREATE TABLE IF NOT EXISTS indicator_latest (drive_id TEXT NOT NULL, indicator_id INTEGER NOT NULL, raw_value REAL, current_value REAL, PRIMARY KEY (drive_id, indicator_id))")
        execute("CREATE TABLE IF NOT EXISTS indicator_history (id INTEGER PRIMARY KEY AUTOINCREMENT, drive_id TEXT NOT NULL, indicator_id INTEGER NOT NULL, taken_at REAL NOT NULL, raw_value REAL, current_value INTEGER)")
        execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, drive_id TEXT NOT NULL, taken_at REAL NOT NULL, kind TEXT, message TEXT)")
        execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        execute("CREATE INDEX IF NOT EXISTS samples_drive ON samples(drive_id, taken_at)")
        execute("CREATE INDEX IF NOT EXISTS indicator_history_drive ON indicator_history(drive_id, indicator_id, taken_at)")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func applyDeltas(_ drives: [DriveSnapshot]) -> [DriveSnapshot] {
        queue.sync {
            drives.map { drive in
                guard drive.hasHealthReading else { return drive }
                var copy = drive
                copy.indicators = drive.indicators.map { indicator in
                    var updated = indicator
                    if let previous = latest(driveID: drive.id, indicator: indicator.id) {
                        if let raw = indicator.raw {
                            let delta = Int64(raw) - Int64(previous.raw.rounded())
                            updated.rawDelta = Int(clamping: delta)
                        }
                    }
                    // NVMe rows arrive without a firmware worst-ever value. Fill the
                    // column with the worst normalized value on record so it stays
                    // meaningful instead of echoing the current value.
                    if updated.worst == nil, let current = updated.current {
                        let recorded = worstCurrent(driveID: drive.id, indicatorID: indicator.id)
                        updated.worst = min(recorded ?? current, current)
                    }
                    return updated
                }
                return copy
            }
        }
    }

    public func record(_ drives: [DriveSnapshot]) {
        queue.sync {
            for drive in drives where drive.hasHealthReading {
                if drive.transport == .nvme {
                    migrateNVMeIndicatorIDs(driveID: drive.id)
                }
                let last = lastSampleDate(drive.id)
                let changed = last.map { drive.checkedAt.timeIntervalSince($0) > 600 } ?? true
                if changed {
                    insertSample(drive)
                    insertIndicatorHistory(drive)
                }
                for indicator in drive.indicators {
                    upsertLatest(driveID: drive.id, indicator: indicator)
                }
            }
        }
    }

    public func samples(driveID: String, limit: Int = 180) -> [HistorySample] {
        queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT id, drive_id, taken_at, health, temperature, ssd_life, bytes_written FROM samples WHERE drive_id = ? ORDER BY taken_at DESC LIMIT ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, driveID)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var rows: [HistorySample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(HistorySample(
                    id: sqlite3_column_int64(statement, 0),
                    driveID: columnText(statement, 1),
                    takenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    health: sqlite3_column_double(statement, 3),
                    temperature: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4),
                    ssdLife: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5),
                    bytesWritten: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6)
                ))
            }
            return rows.reversed()
        }
    }

    public func events(driveID: String, limit: Int = 40) -> [DriveEvent] {
        queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT id, taken_at, kind, message FROM events WHERE drive_id = ? ORDER BY taken_at DESC LIMIT ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, driveID)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var rows: [DriveEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(DriveEvent(
                    id: sqlite3_column_int64(statement, 0),
                    takenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    kind: columnText(statement, 2),
                    message: columnText(statement, 3)
                ))
            }
            return rows
        }
    }

    public func addEvent(driveID: String, kind: String, message: String, at date: Date = Date()) {
        queue.sync {
            var statement: OpaquePointer?
            let sql = "INSERT INTO events (drive_id, taken_at, kind, message) VALUES (?, ?, ?, ?)"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, driveID)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            bindText(statement, 3, kind)
            bindText(statement, 4, message)
            sqlite3_step(statement)
        }
    }

    public func writeRateDescription(driveID: String, latestBytes: UInt64?) -> String? {
        let rows = samples(driveID: driveID, limit: 60).filter { $0.bytesWritten != nil }
        guard let newest = rows.last, let oldest = rows.first, let end = newest.bytesWritten, let start = oldest.bytesWritten else {
            return latestBytes == nil ? nil : "Write rate appears after DriveClue has two saved checks."
        }
        let seconds = newest.takenAt.timeIntervalSince(oldest.takenAt)
        guard seconds >= 3600, end >= start else {
            return "Write rate appears after DriveClue has checks at least an hour apart."
        }
        let perDay = (end - start) / seconds * 86_400
        return "About \(ByteFormat.bytes(UInt64(perDay))) written per day over the saved history."
    }

    /// Saved values of one indicator, oldest first.
    public func indicatorSamples(driveID: String, indicatorID: Int, limit: Int = 400) -> [IndicatorSample] {
        queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT id, taken_at, raw_value, current_value FROM indicator_history WHERE drive_id = ? AND indicator_id = ? ORDER BY taken_at DESC LIMIT ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, driveID)
            sqlite3_bind_int(statement, 2, Int32(indicatorID))
            sqlite3_bind_int(statement, 3, Int32(limit))
            var rows: [IndicatorSample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(IndicatorSample(
                    id: sqlite3_column_int64(statement, 0),
                    takenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    raw: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2),
                    current: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3))
                ))
            }
            return rows.reversed()
        }
    }

    /// Change of one indicator over the last `days` of saved checks, or nil when the
    /// saved history is too short to describe a trend.
    public func indicatorTrend(driveID: String, indicatorID: Int, days: Int = 30) -> IndicatorTrend? {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let samples = indicatorSamples(driveID: driveID, indicatorID: indicatorID, limit: 600).filter { $0.takenAt >= cutoff }
        guard samples.count >= 2 else { return nil }
        let first = samples[0]
        let last = samples[samples.count - 1]
        let spanDays = last.takenAt.timeIntervalSince(first.takenAt) / 86_400
        guard spanDays >= 0.5 else { return nil }
        if let firstRaw = first.raw, let lastRaw = last.raw {
            return IndicatorTrend(change: Int64(lastRaw) - Int64(firstRaw), spanDays: spanDays, sampleCount: samples.count)
        }
        if let firstCurrent = first.current, let lastCurrent = last.current {
            return IndicatorTrend(change: Int64(lastCurrent - firstCurrent), spanDays: spanDays, sampleCount: samples.count)
        }
        return nil
    }

    /// Estimate when SSD life reaches 20% if wear continues at the recorded rate,
    /// or nil while the saved history is too short, too steady, or too noisy to project.
    public func lifeProjectionDescription(driveID: String, latestLife: Double?) -> String? {
        let points = samples(driveID: driveID, limit: 400).compactMap { sample -> (date: Date, life: Double)? in
            sample.ssdLife.map { (sample.takenAt, $0) }
        }
        guard points.count >= 5, let first = points.first, let last = points.last else { return nil }
        let spanDays = last.date.timeIntervalSince(first.date) / 86_400
        guard spanDays >= 30 else { return nil }
        let current = latestLife ?? last.life
        guard current > 20 else { return "SSD life is already below 20%." }
        let slopePerDay = (last.life - first.life) / spanDays
        guard slopePerDay < -0.0005 else { return nil }
        let daysTo20 = (current - 20) / -slopePerDay
        guard daysTo20.isFinite, daysTo20 > 0, daysTo20 < 50 * 365 else { return nil }
        let perMonth = -slopePerDay * 30
        let rate = perMonth >= 10 ? String(format: "%.0f%%", perMonth) : String(format: "%.1f%%", perMonth)
        return "SSD life falls about \(rate) per month. At the current rate, 20% remains in \(duration(days: daysTo20))."
    }

    private func duration(days: Double) -> String {
        if days >= 730 {
            return String(format: "about %.1f years", days / 365)
        }
        if days >= 60 {
            return "about \(Int((days / 30.44).rounded())) months"
        }
        return "about \(Int(days.rounded())) days"
    }

    /// Lowest normalized value recorded for an indicator across saved checks.
    private func worstCurrent(driveID: String, indicatorID: Int) -> Int? {
        var statement: OpaquePointer?
        let sql = "SELECT MIN(current_value) FROM indicator_history WHERE drive_id = ? AND indicator_id = ? AND current_value IS NOT NULL"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, driveID)
        sqlite3_bind_int(statement, 2, Int32(indicatorID))
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Recorded temperature extremes for one drive, or nil when no temperature was
    /// saved yet.
    public func temperatureRange(driveID: String) -> (min: Int, max: Int)? {
        queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT MIN(temperature), MAX(temperature) FROM samples WHERE drive_id = ? AND temperature IS NOT NULL"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, driveID)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return (Int(sqlite3_column_double(statement, 0).rounded()), Int(sqlite3_column_double(statement, 1).rounded()))
        }
    }

    /// One-time remap of saved per-indicator history: NVMe rows used app-specific IDs
    /// 8–12 before the standard NVMe health-log numbering landed (8 Host Read Commands
    /// … 12 Power-On Hours … 15 Error Log Entries). Runs once per NVMe drive, tracked
    /// in the `meta` table, and never touches ATA attribute history.
    private func migrateNVMeIndicatorIDs(driveID: String) {
        let key = "nvme_std_ids:\(driveID)"
        if metaValue(key) != nil { return }
        // Apply high targets first so remapped rows are never overwritten.
        let remaps: [(from: Int32, to: Int32)] = [(12, 15), (11, 14), (10, 13), (9, 11), (8, 12)]
        for remap in remaps {
            executeBound("UPDATE indicator_history SET indicator_id = ? WHERE drive_id = ? AND indicator_id = ?", ints: [remap.to], text: driveID, match: remap.from)
            executeBound("UPDATE indicator_latest SET indicator_id = ? WHERE drive_id = ? AND indicator_id = ?", ints: [remap.to], text: driveID, match: remap.from)
        }
        setMetaValue(key, "1")
    }

    private func metaValue(_ key: String) -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private func setMetaValue(_ key: String, _ value: String) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        bindText(statement, 2, value)
        sqlite3_step(statement)
    }

    private func executeBound(_ sql: String, ints: [Int32], text: String, match: Int32) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, ints[0])
        bindText(statement, 2, text)
        sqlite3_bind_int(statement, 3, match)
        sqlite3_step(statement)
    }

    private func insertSample(_ drive: DriveSnapshot) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO samples (drive_id, taken_at, health, temperature, ssd_life, bytes_written) VALUES (?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, drive.id)
        sqlite3_bind_double(statement, 2, drive.checkedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, drive.overallHealth)
        bindOptional(statement, 4, drive.temperatureCelsius.map { Double($0) })
        bindOptional(statement, 5, drive.ssdLife)
        bindOptional(statement, 6, drive.bytesWritten.map { Double($0) })
        sqlite3_step(statement)
    }

    /// Runs inside `record`'s `queue.sync` block: saves one point per indicator at
    /// sample cadence so per-attribute trends can be charted later.
    private func insertIndicatorHistory(_ drive: DriveSnapshot) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO indicator_history (drive_id, indicator_id, taken_at, raw_value, current_value) VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        let timestamp = drive.checkedAt.timeIntervalSince1970
        for indicator in drive.indicators {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bindText(statement, 1, drive.id)
            sqlite3_bind_int(statement, 2, Int32(indicator.id))
            sqlite3_bind_double(statement, 3, timestamp)
            if let raw = indicator.raw {
                sqlite3_bind_double(statement, 4, Double(raw))
            } else {
                sqlite3_bind_null(statement, 4)
            }
            if let current = indicator.current {
                sqlite3_bind_int(statement, 5, Int32(clamping: current))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_step(statement)
        }
    }

    private func upsertLatest(driveID: String, indicator: HealthIndicator) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO indicator_latest (drive_id, indicator_id, raw_value, current_value) VALUES (?, ?, ?, ?) ON CONFLICT(drive_id, indicator_id) DO UPDATE SET raw_value = excluded.raw_value, current_value = excluded.current_value"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, driveID)
        sqlite3_bind_int(statement, 2, Int32(indicator.id))
        let rawValue = indicator.raw.map { Double($0) }
        bindOptional(statement, 3, rawValue)
        bindOptional(statement, 4, indicator.current.map { Double($0) })
        sqlite3_step(statement)
    }

    private func latest(driveID: String, indicator: Int) -> (raw: Double, current: Int)? {
        var statement: OpaquePointer?
        let sql = "SELECT raw_value, current_value FROM indicator_latest WHERE drive_id = ? AND indicator_id = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, driveID)
        sqlite3_bind_int(statement, 2, Int32(indicator))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let raw = sqlite3_column_type(statement, 0) == SQLITE_NULL ? 0 : sqlite3_column_double(statement, 0)
        let current = sqlite3_column_type(statement, 1) == SQLITE_NULL ? 0 : Int(sqlite3_column_int(statement, 1))
        return (raw, current)
    }

    private func lastSampleDate(_ driveID: String) -> Date? {
        var statement: OpaquePointer?
        let sql = "SELECT taken_at FROM samples WHERE drive_id = ? ORDER BY taken_at DESC LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, driveID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func execute(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        sqlite3_exec(database, sql, nil, nil, &error)
        if let error { sqlite3_free(error) }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, SQLITE_TRANSIENT)
        }
    }

    private func bindOptional(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Keep the existing location so saved drive samples remain available after the rename.
        return base.appendingPathComponent("DriveStats", isDirectory: true).appendingPathComponent("history.sqlite")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension Int {
    init(clamping value: Int64) {
        if value > Int64(Int.max) { self = Int.max }
        else if value < Int64(Int.min) { self = Int.min }
        else { self = Int(value) }
    }
}
