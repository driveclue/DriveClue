import Foundation
import XCTest
@testable import DriveClueCore

final class SettingsMigrationTests: XCTestCase {
    func testLegacyEmailPreferencesDoNotResetOtherSettings() throws {
        let suite = "DriveClueSettingsMigration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AppSettings(checkIntervalMinutes: 45, weeklyAllClear: true)
        )) as? [String: Any])
        stored["emailEnabled"] = true
        stored["emailTo"] = "old@example.com"
        stored["smtpHost"] = "smtp.example.com"
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: AppSettings.storageKey)

        let loaded = AppSettings.load(defaults: defaults)
        XCTAssertEqual(loaded.checkIntervalMinutes, 45)
        XCTAssertTrue(loaded.weeklyAllClear)

        loaded.save(defaults: defaults)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(
            defaults.data(forKey: AppSettings.storageKey)
        )) as? [String: Any])
        XCTAssertNil(saved["emailEnabled"])
        XCTAssertNil(saved["emailTo"])
        XCTAssertNil(saved["smtpHost"])
    }
}
