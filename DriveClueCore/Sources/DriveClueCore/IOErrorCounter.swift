import Foundation
import OSLog

public enum IOErrorCounter {
    public static func countIfAvailable(bsdName: String) -> Int? {
        guard let store = try? OSLogStore(scope: .system) else { return nil }
        let start = Date().addingTimeInterval(-min(ProcessInfo.processInfo.systemUptime, 6 * 60 * 60))
        let position = store.position(date: start)
        let predicate = NSPredicate(format: "eventMessage CONTAINS[c] %@ AND eventMessage CONTAINS[c] 'error'", "/dev/\(bsdName)")
        guard let entries = try? store.getEntries(with: [], at: position, matching: predicate) else { return nil }
        var count = 0
        for case let entry as OSLogEntryLog in entries {
            let message = entry.composedMessage.lowercased()
            if message.contains("i/o error") || message.contains("disk i/o") {
                count += 1
            }
            if count >= 200 { break }
        }
        return count
    }
}
