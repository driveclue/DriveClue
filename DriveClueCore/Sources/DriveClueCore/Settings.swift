import Foundation
import OSLog

public enum EmailReportTrigger: String, Codable, CaseIterable, Sendable {
    case onIssue
    case onAnyChange
    case scheduledOnly

    public var title: String {
        switch self {
        case .onIssue: "On warning or issue found"
        case .onAnyChange: "When a reading changes"
        case .scheduledOnly: "Only the scheduled report"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var checkIntervalMinutes: Int
    public var launchAtLogin: Bool
    public var showMenuBarIcon: Bool
    public var menuBarOnly: Bool
    public var monochromeMenuBarIcon: Bool
    public var emailEnabled: Bool
    public var emailTrigger: EmailReportTrigger
    public var emailHealthEnabled: Bool
    public var emailHealthBelow: Int
    public var emailPerformanceEnabled: Bool
    public var emailPerformanceBelow: Int
    public var emailSSDLifeEnabled: Bool
    public var emailSSDLifeBelow: Int
    public var emailOnSelfTestComplete: Bool
    public var emailUseAppleMail: Bool
    public var emailTo: String
    public var emailFrom: String
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpUseTLS: Bool
    public var smtpUseAuth: Bool
    public var smtpUsername: String
    public var dailyReportEnabled: Bool
    public var dailyReportHour: Int
    public var weeklyAllClear: Bool
    public var freeSpaceThresholds: [String: Int]
    public var updateFeedURL: String

    public init(
        checkIntervalMinutes: Int = 30,
        launchAtLogin: Bool = false,
        showMenuBarIcon: Bool = true,
        menuBarOnly: Bool = false,
        monochromeMenuBarIcon: Bool = true,
        emailEnabled: Bool = false,
        emailTrigger: EmailReportTrigger = .onIssue,
        emailHealthEnabled: Bool = true,
        emailHealthBelow: Int = 30,
        emailPerformanceEnabled: Bool = true,
        emailPerformanceBelow: Int = 50,
        emailSSDLifeEnabled: Bool = true,
        emailSSDLifeBelow: Int = 20,
        emailOnSelfTestComplete: Bool = true,
        emailUseAppleMail: Bool = true,
        emailTo: String = "",
        emailFrom: String = "",
        smtpHost: String = "",
        smtpPort: Int = 587,
        smtpUseTLS: Bool = true,
        smtpUseAuth: Bool = false,
        smtpUsername: String = "",
        dailyReportEnabled: Bool = false,
        dailyReportHour: Int = 9,
        weeklyAllClear: Bool = false,
        freeSpaceThresholds: [String: Int] = [:],
        updateFeedURL: String = ""
    ) {
        self.checkIntervalMinutes = checkIntervalMinutes
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.menuBarOnly = menuBarOnly
        self.monochromeMenuBarIcon = monochromeMenuBarIcon
        self.emailEnabled = emailEnabled
        self.emailTrigger = emailTrigger
        self.emailHealthEnabled = emailHealthEnabled
        self.emailHealthBelow = emailHealthBelow
        self.emailPerformanceEnabled = emailPerformanceEnabled
        self.emailPerformanceBelow = emailPerformanceBelow
        self.emailSSDLifeEnabled = emailSSDLifeEnabled
        self.emailSSDLifeBelow = emailSSDLifeBelow
        self.emailOnSelfTestComplete = emailOnSelfTestComplete
        self.emailUseAppleMail = emailUseAppleMail
        self.emailTo = emailTo
        self.emailFrom = emailFrom
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUseTLS = smtpUseTLS
        self.smtpUseAuth = smtpUseAuth
        self.smtpUsername = smtpUsername
        self.dailyReportEnabled = dailyReportEnabled
        self.dailyReportHour = dailyReportHour
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
