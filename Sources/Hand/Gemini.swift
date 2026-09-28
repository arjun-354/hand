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
    func answer(question: String, selectedText: String, lookingAt: [String: String], screenText: [String],
                image: Data? = nil) async throws -> String {
        let prompt = """
        You are Hand, a voice assistant on a Mac. Answer the user's request for display in a small reading panel.
        Style: direct, no preamble. Short paragraphs or "- " bullets, **bold** for key terms, no headings, no tables.
        Keep it under 180 words unless the user asked for detail.

        User said (speech-to-text, may be misheard): "\(question)"
        App and page they're on: \(lookingAt.isEmpty ? "unknown" : "\(lookingAt)")
        \(selectedText.isEmpty ? "No text is selected." : "Text they selected:\n\"\"\"\n\(selectedText.prefix(20_000))\n\"\"\"")
        \(selectedText.isEmpty && !screenText.isEmpty ? "Text visible on their screen:\n\(screenText.prefix(250).joined(separator: "\n"))" : "")
        """
        let withImage = image == nil ? prompt : prompt + "\nThe attached image is the window they are looking at."
        return try await generate(withImage, json: false, image: image).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Looks at what's on screen and turns a taste call ("a song that fits this picture")
    /// into something concrete Hand can search for or type.
    func choose(for request: String, image: Data) async throws -> (value: String, why: String) {
        let prompt = """
        The attached image is what the user is looking at on their Mac. They said (speech-to-text): "\(request)"
        Decide the one concrete thing a computer should search for or type to do this, based on what you see.
        Be specific: for music pick one real, well-known song and write it as "Title Artist" (no dash, good for a search box);
        for a place, the exact place name; for a caption or reply, the full text.
        Reply with JSON only: {"value": string, "why": string (under 12 words)}
        """
        struct Choice: Decodable { let value: String; let why: String? }
        let raw = try await generate(prompt, json: true, image: image)
        let choice = try JSONDecoder().decode(Choice.self, from: Data(raw.utf8))
        return (choice.value.trimmingCharacters(in: .whitespacesAndNewlines), choice.why ?? "")
    }

    // MARK: - API

    /// Tries models best-first. Free keys get ~20 requests per model per day, so a model
    /// that hits its daily quota is skipped until the reset; busy ones are just passed over.
    func generate(_ prompt: String, json: Bool = true, image: Data? = nil) async throws -> String {
        let models = try await Self.models(apiKey: apiKey).filter { !Self.isExhausted($0) }
        var lastError: Error = Failure.noModel
        for (i, model) in models.prefix(12).enumerated() {
            do {
                let text = try await generate(prompt, model: model, json: json, image: image)
                if i > 0 { Self.promote(model) }  // remember what worked
                return text
            } catch Failure.http(let code, let body) where [404, 429, 500, 503].contains(code) {
                if code == 404 { Self.drop(model) }
                if code == 429 && body.contains("PerDay") { Self.markExhausted(model) }
                log("gemini \(model) unavailable (\(code)); trying next")
                lastError = Failure.http(code, body)
            }
        }
        throw lastError
    }

    // Free-tier daily quotas reset at midnight Pacific time.
    // Remembered across launches so restarts don't spend requests rediscovering it.
    private static var exhaustedUntil: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "geminiExhaustedUntil") as? [String: Date]) ?? [:]
    }() {
        didSet { UserDefaults.standard.set(exhaustedUntil, forKey: "geminiExhaustedUntil") }
    }

    private static func isExhausted(_ model: String) -> Bool {
        guard let until = exhaustedUntil[model] else { return false }
        if Date() >= until { exhaustedUntil[model] = nil; return false }
        return true
    }

    private static func markExhausted(_ model: String) {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let reset = pacific.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(86_400)
        exhaustedUntil[model] = reset
        log("gemini \(model) used up its free daily quota; skipping until \(reset)")
    }

    /// Models this key can't use at all (retired for new users); also remembered.
    private static var unavailable: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "geminiUnavailable") ?? []) {
        didSet { UserDefaults.standard.set(Array(unavailable), forKey: "geminiUnavailable") }
    }

    private static func drop(_ model: String) {
        cachedModels?.removeAll { $0 == model }
        unavailable.insert(model)
    }

    private func generate(_ prompt: String, model: String, json: Bool, image: Data?) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.base)/\(model):generateContent")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": (image.map { [["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]]] } ?? [])
                + [["text": prompt]]]],
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
        let skip = ["image", "tts", "live", "audio", "embedding", "thinking", "exp", "robotics", "computer", "omni"]
        let names = models.filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
            .compactMap { $0["name"] as? String }
            .filter { n in n.contains("flash") && !skip.contains { n.contains($0) } }
            .sorted { a, b in
                let (la, lb) = (a.contains("lite"), b.contains("lite"))
                if la != lb { return lb }  // full models before lite ones
                let (va, vb) = (version(a), version(b))
                if va != vb { return va > vb }
                return !a.contains("preview") && b.contains("preview")  // stable over preview
            }
        let usable = names.filter { !unavailable.contains($0) }
        guard !usable.isEmpty else { throw Failure.noModel }
        cachedModels = usable
        log("gemini models: \(usable.count) usable, \(exhaustedUntil.filter { $0.value > Date() }.count) out of quota today")
        return usable
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
