import Foundation

enum UpdateChecker {
    static func summary(feed: String) async -> String {
        let trimmed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return "No update feed is configured. DriveClue \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") is the installed build."
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return "The update feed returned status \(status)." }
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("sparkle:version") || body.contains("<item>") {
                return "The appcast responded. Compare its version with \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") before replacing the app."
            }
            return "The update feed responded, but it does not look like a Sparkle appcast."
        } catch {
            return error.localizedDescription
        }
    }
}
