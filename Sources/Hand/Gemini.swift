import Foundation

/// Google Gemini: the slow, smart half. Plans multi-step tasks and writes text
/// Jev can't (messages, names, notes). Jev still makes every per-step decision.
struct Gemini {
    let apiKey: String
    private static let base = "https://generativelanguage.googleapis.com/v1beta"
    /// Chosen once per launch from the models this key can use (or GEMINI_MODEL).
    private static var cachedModel: String?

    struct Plan: Decodable {
        var steps: [String] = []
        /// Text the plan needs typed (a message body, a file name, a note).
        var texts: [String] = []
        /// For questions: a short spoken-style answer instead of actions.
        var answer: String?
    }

    enum Failure: Error, CustomStringConvertible {
        case http(Int, String), noModel, empty
        var description: String {
            switch self {
            case .http(let code, let body): "Gemini error \(code): \(body.prefix(200))"
            case .noModel: "No Gemini model available for this key"
            case .empty: "Gemini returned nothing"
            }
        }
    }

    static func fromConfig() -> Gemini? {
        Config.value("GEMINI_API_KEY").map { Gemini(apiKey: $0) }
    }

    // MARK: - What Hand asks

    func plan(goal: String, app: String, window: String, screen: [String],
              lookingAt: [String: String], stepsDone: [String]) async throws -> Plan {
        let prompt = """
        You plan actions for Hand, a voice assistant that operates a Mac by clicking and typing.
        A fast executor will carry out your plan one step at a time by picking items from the screen list,
        so write each step as a short instruction that names an item visible on screen when possible
        (e.g. "Click New page in the Scripting column", "Type the reel link into the page title").

        User said (speech-to-text, may be misheard): "\(goal)"
        Front app: \(app) — window "\(window)"
        What the user was looking at when they spoke: \(lookingAt.isEmpty ? "unknown" : "\(lookingAt)")
        Steps already done: \(stepsDone.isEmpty ? "none" : stepsDone.joined(separator: "; "))
        Items on screen:
        \(screen.prefix(180).joined(separator: "\n"))

        Rules:
        - At most 6 steps, starting from the current screen. Use the app's normal UI and keyboard-free actions.
        - Put any text that must be typed (message body, title, file name, search query) in "texts", exactly as it should appear.
          If the user asked to paste something they were looking at, use that exact value.
        - Never plan sending, deleting, buying or posting unless the user explicitly asked for it.
        - If the request is a question that needs no action on the computer, leave steps empty and put a one-sentence answer in "answer".

        Reply with JSON only: {"steps": [string], "texts": [string], "answer": string or null}
        """
        let raw = try await generate(prompt)
        return try JSONDecoder().decode(Plan.self, from: Data(raw.utf8))
    }

    // MARK: - API

    func generate(_ prompt: String) async throws -> String {
        let model = try await Self.model(apiKey: apiKey)
        var request = URLRequest(url: URL(string: "\(Self.base)/\(model):generateContent")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status, String(decoding: data, as: UTF8.self)) }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parts = ((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }

    /// Picks the newest general-purpose Flash model this key can call.
    private static func model(apiKey: String) async throws -> String {
        if let override = Config.value("GEMINI_MODEL") { return override.hasPrefix("models/") ? override : "models/\(override)" }
        if let cachedModel { return cachedModel }
        var request = URLRequest(url: URL(string: "\(base)/models?pageSize=200")!, timeoutInterval: 10)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status, String(decoding: data, as: UTF8.self)) }
        let models = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]]) ?? []
        let skip = ["lite", "image", "tts", "live", "audio", "embedding", "thinking", "exp", "robotics", "computer"]
        let names = models.filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
            .compactMap { $0["name"] as? String }
            .filter { n in n.contains("flash") && !skip.contains { n.contains($0) } }
        // Highest version first, stable over preview.
        guard let best = names.sorted(by: { a, b in
            let (va, vb) = (version(a), version(b))
            if va != vb { return va > vb }
            return !a.contains("preview") && b.contains("preview")
        }).first else { throw Failure.noModel }
        cachedModel = best
        log("gemini model: \(best)")
        return best
    }

    private static func version(_ name: String) -> Double {
        let digits = name.split(separator: "-").first { Double($0) != nil }
        return digits.flatMap { Double($0) } ?? 0
    }
}
