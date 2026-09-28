import Foundation

/// Keeps secrets on screen (API keys, tokens, passwords) out of everything Hand
/// sends to Jev or Brain and out of its logs.
enum Redact {
    // Long unbroken runs of key-like characters: API keys, tokens, hashes.
    private static let token = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-\.\+/=]{24,}"#)

    static func secrets(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return token.stringByReplacingMatches(in: text, range: range, withTemplate: "[hidden]")
    }

    /// Windows that are clearly secret files: never read their contents at all.
    static func isSecretWindow(_ title: String) -> Bool {
        let t = title.lowercased()
        return [".env", "credentials", "secret", ".pem", "id_rsa", "keychain", "password"].contains { t.contains($0) }
    }
}
