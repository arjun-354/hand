import Foundation
import Security

/// Account tokens (Slack, Gmail) live in the macOS Keychain, not in ~/.config/hand/.env:
/// they unlock whole accounts, so they get the system's protected store.
enum Keychain {
    static let service = "com.arjun.hand"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }
}
