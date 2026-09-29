import Foundation

/// Read-only Slack connector using a user token (xoxp-) from the Keychain.
/// Scopes: search, history and read for channels/DMs/groups, and users:read.
struct Slack {
    let token: String
    private static let base = "https://slack.com/api/"
    /// Workspace members, cached per launch: id -> (name, display name).
    private static var people: [String: (name: String, display: String)] = [:]
    private static var me: String?

    struct Message {
        let channel: String
        let author: String
        let text: String
        let date: Date
        let link: String?

        /// One line for the Brain: "Mon 14:02 · #design · Ritesh: can you send the cut?"
        var line: String {
            let f = DateFormatter()
            f.dateFormat = "EEE d MMM HH:mm"
            return "\(f.string(from: date)) · \(channel) · \(author): \(Redact.secrets(text.prefix(600).description))"
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case api(String)
        var description: String {
            switch self {
            case .api("invalid_auth"), .api("not_authed"), .api("token_revoked"): "Slack token isn't valid — run scripts/slack-token.sh"
            case .api("missing_scope"): "The Slack app is missing a permission — reinstall it from the manifest"
            case .api(let code): "Slack error: \(code)"
            }
        }
    }

    static func fromKeychain() -> Slack? { Keychain.read("slack-user-token").map { Slack(token: $0) } }

    // MARK: - What Hand asks

    /// Slack search (same syntax as the app's search box).
    func search(_ query: String, limit: Int = 40) async throws -> [Message] {
        let json = try await call("search.messages", ["query": query, "count": "\(limit)", "sort": "timestamp"])
        let matches = ((json["messages"] as? [String: Any])?["matches"] as? [[String: Any]]) ?? []
        var out: [Message] = []
        for m in matches {
            let channel = (m["channel"] as? [String: Any]).map { c -> String in
                if (c["is_im"] as? Bool) == true { return "DM" }
                return "#" + ((c["name"] as? String) ?? "?")
            } ?? "?"
            let author = try await name(of: m["user"] as? String) ?? (m["username"] as? String) ?? "?"
            out.append(Message(channel: channel, author: author, text: await readable(m["text"] as? String ?? ""),
                               date: Self.date(m["ts"]), link: m["permalink"] as? String))
        }
        return out
    }

    /// Recent direct messages (1:1 and group DMs) from the last `hours`, newest first.
    func recentDMs(hours: Double, limit: Int = 60) async throws -> [Message] {
        let oldest = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970
        let list = try await call("conversations.list", ["types": "im,mpim", "limit": "200", "exclude_archived": "true"])
        let channels = (list["channels"] as? [[String: Any]]) ?? []
        // Only conversations touched recently; history calls are rate limited.
        let recent = channels.filter { (($0["updated"] as? Double) ?? 0) / 1000 >= oldest || $0["updated"] == nil }.prefix(25)
        var out: [Message] = []
        for c in recent {
            guard let id = c["id"] as? String else { continue }
            let label: String
            if let user = c["user"] as? String { label = "DM with \(try await name(of: user) ?? "someone")" }
            else { label = "group DM" }
            let history = try await call("conversations.history", ["channel": id, "oldest": "\(oldest)", "limit": "30"])
            for m in (history["messages"] as? [[String: Any]]) ?? [] where m["subtype"] == nil {
                out.append(Message(channel: label, author: try await name(of: m["user"] as? String) ?? "?",
                                   text: await readable(m["text"] as? String ?? ""), date: Self.date(m["ts"]), link: nil))
            }
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Messages that @-mention you in the last `days`.
    func mentions(days: Int) async throws -> [Message] {
        guard let me = try await myID() else { return [] }
        return try await search("<@\(me)> after:\(Self.day(daysAgo: days + 1))")
    }

    /// Finds a workspace member by (part of) their name, for "from:" searches.
    func person(named query: String) async throws -> String? {
        try await loadPeople()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return Self.people.first { $0.value.name.lowercased() == q || $0.value.display.lowercased() == q }?.key
            ?? Self.people.first { $0.value.name.lowercased().contains(q) || $0.value.display.lowercased().contains(q) }?.key
    }

    static func day(daysAgo: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    // MARK: - Helpers

    func myID() async throws -> String? {
        if let me = Self.me { return me }
        let json = try await call("auth.test", [:])
        Self.me = json["user_id"] as? String
        return Self.me
    }

    private func loadPeople() async throws {
        guard Self.people.isEmpty else { return }
        var cursor = ""
        repeat {
            let json = try await call("users.list", ["limit": "500", "cursor": cursor])
            for u in (json["members"] as? [[String: Any]]) ?? [] {
                guard let id = u["id"] as? String, (u["deleted"] as? Bool) != true else { continue }
                let profile = u["profile"] as? [String: Any]
                Self.people[id] = ((u["real_name"] as? String) ?? (u["name"] as? String) ?? id,
                                   (profile?["display_name"] as? String) ?? "")
            }
            cursor = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
        } while !cursor.isEmpty
    }

    private func name(of id: String?) async throws -> String? {
        guard let id else { return nil }
        try await loadPeople()
        guard let p = Self.people[id] else { return nil }
        return p.display.isEmpty ? p.name : p.display
    }

    /// Turns <@U123> mentions and <url|label> links into readable text.
    private func readable(_ text: String) async -> String {
        var out = text
        while let r = out.range(of: #"<@([A-Z0-9]+)>"#, options: .regularExpression) {
            let id = String(out[r].dropFirst(2).dropLast())
            out.replaceSubrange(r, with: "@" + ((try? await name(of: id)) ?? id))
        }
        out = out.replacingOccurrences(of: #"<(https?://[^|>]+)\|([^>]+)>"#, with: "$2 ($1)", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        return out
    }

    private static func date(_ ts: Any?) -> Date {
        Date(timeIntervalSince1970: Double((ts as? String) ?? "") ?? 0)
    }

    private func call(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: Self.base + method)!
        components.queryItems = params.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 429, attempt == 0 {
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
                try await Task.sleep(for: .seconds(min(wait, 5)))
                continue
            }
            let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard json["ok"] as? Bool == true else { throw Failure.api(json["error"] as? String ?? "unknown") }
            return json
        }
        throw Failure.api("ratelimited")
    }
}
