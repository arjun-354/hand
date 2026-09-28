import Foundation

/// Google Gemini: the slow, smart half. Plans multi-step tasks and writes text
/// Jev can't (messages, names, notes). Jev still makes every per-step decision.
struct Gemini {
    let apiKey: String
    private static let base = "https://generativelanguage.googleapis.com/v1beta"
    /// Chosen once per launch from the models this key can use (or GEMINI_MODEL).
    private static var cachedModels: [String]?

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

    /// Looks up the model list at launch so the first plan doesn't pay for it.
    func warmUp() { Task { _ = try? await Self.models(apiKey: apiKey) } }

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

    /// A readable answer for the notch panel: summaries, explanations, questions.
    func answer(question: String, selectedText: String, lookingAt: [String: String], screenText: [String]) async throws -> String {
        let prompt = """
        You are Hand, a voice assistant on a Mac. Answer the user's request for display in a small reading panel.
        Style: direct, no preamble. Short paragraphs or "- " bullets, **bold** for key terms, no headings, no tables.
        Keep it under 180 words unless the user asked for detail.

        User said (speech-to-text, may be misheard): "\(question)"
        App and page they're on: \(lookingAt.isEmpty ? "unknown" : "\(lookingAt)")
        \(selectedText.isEmpty ? "No text is selected." : "Text they selected:\n\"\"\"\n\(selectedText.prefix(20_000))\n\"\"\"")
        \(selectedText.isEmpty && !screenText.isEmpty ? "Text visible on their screen:\n\(screenText.prefix(250).joined(separator: "\n"))" : "")
        """
        return try await generate(prompt, json: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - API

    /// Tries the best model first and falls back when one is overloaded or rate-limited.
    func generate(_ prompt: String, json: Bool = true) async throws -> String {
        let models = try await Self.models(apiKey: apiKey)
        var lastError: Error = Failure.noModel
        // Newest two, then the stable workhorses, which are rarely overloaded.
        var order = Array(models.prefix(2))
        for stable in ["models/gemini-flash-latest", "models/gemini-2.5-flash"] where models.contains(stable) && !order.contains(stable) {
            order.append(stable)
        }
        for (i, model) in order.enumerated() {
            do {
                let text = try await generate(prompt, model: model, json: json)
                if i > 0 { Self.promote(model) }  // remember what worked
                return text
            } catch Failure.http(let code, let body) where [429, 500, 503].contains(code) {
                log("gemini \(model) busy (\(code)); trying next")
                lastError = Failure.http(code, body)
            }
        }
        throw lastError
    }

    private func generate(_ prompt: String, model: String, json: Bool) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.base)/\(model):generateContent")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": json ? "application/json" : "text/plain", "temperature": 0.2],
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

    /// General-purpose Flash models this key can call, newest first (or GEMINI_MODEL alone).
    private static func models(apiKey: String) async throws -> [String] {
        if let override = Config.value("GEMINI_MODEL") { return [override.hasPrefix("models/") ? override : "models/\(override)"] }
        if let cachedModels { return cachedModels }
        var request = URLRequest(url: URL(string: "\(base)/models?pageSize=200")!, timeoutInterval: 10)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status, String(decoding: data, as: UTF8.self)) }
        let models = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]]) ?? []
        let skip = ["lite", "image", "tts", "live", "audio", "embedding", "thinking", "exp", "robotics", "computer", "omni"]
        let names = models.filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
            .compactMap { $0["name"] as? String }
            .filter { n in n.contains("flash") && !skip.contains { n.contains($0) } }
            .sorted { a, b in
                let (va, vb) = (version(a), version(b))
                if va != vb { return va > vb }
                return !a.contains("preview") && b.contains("preview")  // stable over preview
            }
        guard !names.isEmpty else { throw Failure.noModel }
        cachedModels = names
        log("gemini models: \(names.prefix(3).joined(separator: ", "))")
        return names
    }

    private static func promote(_ model: String) {
        guard var list = cachedModels, let i = list.firstIndex(of: model) else { return }
        list.remove(at: i)
        list.insert(model, at: 0)
        cachedModels = list
        log("gemini model now: \(model)")
    }

    private static func version(_ name: String) -> Double {
        let digits = name.split(separator: "-").first { Double($0) != nil }
        return digits.flatMap { Double($0) } ?? 0
    }
}
