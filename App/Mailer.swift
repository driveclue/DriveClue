import DriveClueCore
import Foundation
import Network
import Security

enum Keychain {
    // Preserve access to SMTP passwords saved by earlier versions.
    private static let service = "DriveStats SMTP"

    static func save(account: String, password: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return password
    }
}

enum MailError: LocalizedError {
    case missingRecipient
    case mailScript(String)
    case smtp(String)

    var errorDescription: String? {
        switch self {
        case .missingRecipient: "Add a recipient address first."
        case .mailScript(let message): message
        case .smtp(let message): message
        }
    }
}

enum MailService {
    static func send(settings: AppSettings, subject: String, body: String) async throws {
        let recipients = settings.emailTo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = recipients.first else { throw MailError.missingRecipient }
        if settings.emailUseAppleMail {
            try sendWithMail(from: settings.emailFrom, to: recipients, subject: subject, body: body)
        } else {
            let password = Keychain.load(account: settings.smtpUsername) ?? ""
            try await SMTPClient().send(
                host: settings.smtpHost,
                port: settings.smtpPort,
                useTLS: settings.smtpUseTLS,
                username: settings.smtpUseAuth ? settings.smtpUsername : "",
                password: settings.smtpUseAuth ? password : "",
                from: settings.emailFrom.isEmpty ? first : settings.emailFrom,
                to: recipients,
                subject: subject,
                body: body
            )
        }
    }

    private static func sendWithMail(from: String, to: [String], subject: String, body: String) throws {
        let recipients = to.map { "make new to recipient at end of to recipients with properties {address:\"\(escape($0))\"}" }.joined(separator: "\n")
        let sender = from.isEmpty ? "" : ", sender:\"\(escape(from))\""
        let source = """
        tell application "Mail"
          set msg to make new outgoing message with properties {subject:"\(escape(subject))", content:"\(escape(body))", visible:false\(sender)}
          tell msg
            \(recipients)
            send
          end tell
        end tell
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Apple Mail could not send the report."
            throw MailError.mailScript(message)
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

final class SMTPClient {
    func send(host: String, port: Int, useTLS: Bool, username: String, password: String, from: String, to: [String], subject: String, body: String) async throws {
        guard !host.isEmpty else { throw MailError.smtp("Enter an SMTP server.") }
        let secure = useTLS || port == 465
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)), using: secure ? .tls : .tcp)
        try await connect(connection)
        _ = try await read(connection)
        try await write(connection, "EHLO driveclue.local\r\n")
        _ = try await read(connection)
        if !username.isEmpty {
            try await write(connection, "AUTH LOGIN\r\n")
            _ = try await read(connection)
            try await write(connection, Data(username.utf8).base64EncodedString() + "\r\n")
            _ = try await read(connection)
            try await write(connection, Data(password.utf8).base64EncodedString() + "\r\n")
            let auth = try await read(connection)
            guard auth.hasPrefix("235") else { throw MailError.smtp(auth) }
        }
        try await write(connection, "MAIL FROM:<\(from)>\r\n")
        _ = try await read(connection)
        for recipient in to {
            try await write(connection, "RCPT TO:<\(recipient)>\r\n")
            _ = try await read(connection)
        }
        try await write(connection, "DATA\r\n")
        _ = try await read(connection)
        let message = "From: \(from)\r\nTo: \(to.joined(separator: ", "))\r\nSubject: \(subject)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n.\r\n"
        try await write(connection, message)
        let accepted = try await read(connection)
        try await write(connection, "QUIT\r\n")
        connection.cancel()
        guard accepted.hasPrefix("250") else { throw MailError.smtp(accepted) }
    }

    private func connect(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: MailError.smtp(error.localizedDescription))
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private func write(_ connection: NWConnection, _ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: MailError.smtp(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    private func read(_ connection: NWConnection) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: MailError.smtp(error.localizedDescription))
                    return
                }
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

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
