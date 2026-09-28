import Foundation

/// Reads keys from the environment, then from ~/.config/hand/.env (never committed).
enum Config {
    static func value(_ name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        let file = URL(fileURLWithPath: NSHomeDirectory() + "/.config/hand/.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'")))
            }
            if parts.count == 2, parts[0] == name, !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }
}
