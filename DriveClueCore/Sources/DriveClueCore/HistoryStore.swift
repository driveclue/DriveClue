import Foundation
import SQLite3

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
        execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, drive_id TEXT NOT NULL, taken_at REAL NOT NULL, kind TEXT, message TEXT)")
        execute("CREATE INDEX IF NOT EXISTS samples_drive ON samples(drive_id, taken_at)")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func applyDeltas(_ drives: [DriveSnapshot]) -> [DriveSnapshot] {
        queue.sync {
            drives.map { drive in
                var copy = drive
                copy.indicators = drive.indicators.map { indicator in
                    var updated = indicator
                    if let previous = latest(driveID: drive.id, indicator: indicator.id) {
                        if let raw = indicator.raw {
                            let delta = Int64(raw) - Int64(previous.raw.rounded())
                            updated.rawDelta = Int(clamping: delta)
                        }
                        if let current = indicator.current {
                            updated.currentDelta = current - previous.current
                        }
                    }
                    return updated
                }
                return copy
            }
        }
    }

    public func record(_ drives: [DriveSnapshot]) {
        queue.sync {
            for drive in drives {
                let last = lastSampleDate(drive.id)
                let changed = last == nil || drive.checkedAt.timeIntervalSince(last!) > 600
                if changed {
                    insertSample(drive)
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
            let sql = "SELECT id, drive_id, taken_at, health, temperature, ssd_life, bytes_written, status FROM samples WHERE drive_id = ? ORDER BY taken_at DESC LIMIT ?"
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
                    bytesWritten: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                    status: columnText(statement, 7)
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

    private func insertSample(_ drive: DriveSnapshot) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO samples (drive_id, taken_at, health, temperature, ssd_life, bytes_written, status) VALUES (?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, drive.id)
        sqlite3_bind_double(statement, 2, drive.checkedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, drive.overallHealth)
        bindOptional(statement, 4, drive.temperatureCelsius.map { Double($0) })
        bindOptional(statement, 5, drive.ssdLife)
        bindOptional(statement, 6, drive.bytesWritten.map { Double($0) })
        bindText(statement, 7, drive.smartStatus.rawValue)
        sqlite3_step(statement)
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
        value.withCString { pointer in
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
