import Foundation
import OSLog

public struct AppSettings: Codable, Equatable, Sendable {
    public var checkIntervalMinutes: Int
    public var launchAtLogin: Bool
    public var showMenuBarIcon: Bool
    public var menuBarOnly: Bool
    public var monochromeMenuBarIcon: Bool
    public var weeklyAllClear: Bool
    public var freeSpaceThresholds: [String: Int]
    public var updateFeedURL: String

    public init(
        checkIntervalMinutes: Int = 30,
        launchAtLogin: Bool = false,
        showMenuBarIcon: Bool = true,
        menuBarOnly: Bool = false,
        monochromeMenuBarIcon: Bool = true,
        weeklyAllClear: Bool = false,
        freeSpaceThresholds: [String: Int] = [:],
        updateFeedURL: String = ""
    ) {
        self.checkIntervalMinutes = checkIntervalMinutes
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.menuBarOnly = menuBarOnly
        self.monochromeMenuBarIcon = monochromeMenuBarIcon
        self.weeklyAllClear = weeklyAllClear
        self.freeSpaceThresholds = freeSpaceThresholds
        self.updateFeedURL = updateFeedURL
    }

    // Retain the original key so upgrades read existing preferences.
    public static let storageKey = "DriveStats.Settings"

    public static func load(defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

public enum IOErrorCounter {
    public static func count(bsdName: String) -> Int {
        guard let store = try? OSLogStore(scope: .system) else { return 0 }
        let start = Date().addingTimeInterval(-min(ProcessInfo.processInfo.systemUptime, 6 * 60 * 60))
        let position = store.position(date: start)
        let predicate = NSPredicate(format: "eventMessage CONTAINS[c] %@ AND eventMessage CONTAINS[c] 'error'", "/dev/\(bsdName)")
        guard let entries = try? store.getEntries(with: [], at: position, matching: predicate) else { return 0 }
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
