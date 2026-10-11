import Foundation

/// App metadata from the bundle, shared by the UI and the update checker.
enum AppInfo {
    static let name = "DriveClue"
    static let gitHubURL = URL(string: "https://github.com/driveclue/DriveClue")!
    static let buyMeACoffeeURL = URL(string: "https://donorbox.org/donate-to-tranit")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var versionLabel: String {
        "Version \(version) (\(build))"
    }

    /// The GitHub URL without its scheme, for display.
    static var gitHubDisplay: String {
        (gitHubURL.host ?? "") + gitHubURL.path
    }
}
