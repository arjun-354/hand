import Foundation

/// The slow, smart half of Hand: plans multi-step tasks, writes text, answers questions
/// and looks at images. Jev still makes every per-step decision. Both providers speak
/// OpenAI-style chat completions.
///  - Groq (default): gpt-oss for text, Qwen for images. Free plan: 1K requests/day and
///    8K tokens/minute per model, so prompts stay small and a busy model falls back.
///  - Meta Model API (paused; BRAIN_PROVIDER=meta): Muse Spark, needs billing set up.
struct Brain {
    enum Provider: String { case groq, meta }

    let provider: Provider
    let apiKey: String

    private var endpoint: URL {
        switch provider {
        case .groq: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .meta: URL(string: "https://api.meta.ai/v1/chat/completions")!
        }
    }

    /// Models to try in order. Each Groq model has its own rate limit, so a fallback helps.
    private func models(forImage: Bool) -> [String] {
        if let pinned = Config.value(provider == .groq ? "GROQ_MODEL" : "META_MODEL"), !forImage { return [pinned] }
        switch provider {
        case .groq: return forImage ? ["qwen/qwen3.8-27b"] : ["openai/gpt-oss-120b", "openai/gpt-oss-20b"]
        // The "-contributor" variants are cheaper but Meta may train on what's sent (screen text).
        case .meta: return ["muse-spark-1.3"]
        }
    }

    struct Plan: Decodable {
        var steps: [String] = []
        /// Text the plan needs typed (a message body, a file name, a note).
        var texts: [String] = []
        /// For questions: a short spoken-style answer instead of actions.
        var answer: String?

        enum CodingKeys: CodingKey { case steps, texts, answer }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            steps = (try? c.decode([String].self, forKey: .steps)) ?? []
            texts = (try? c.decode([String].self, forKey: .texts)) ?? []
            answer = try? c.decode(String.self, forKey: .answer)
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case http(Int, String), empty
        var description: String {
            switch self {
            case .http(401, _): "The Brain's API key was rejected"
            case .http(429, _): "Brain rate limit hit"
            case .http(let code, let body): "Brain error \(code): \(body.prefix(200))"
            case .empty: "The Brain returned nothing"
            }
        }
    }

    static func fromConfig() -> Brain? {
        let choice = Config.value("BRAIN_PROVIDER").flatMap(Provider.init(rawValue:))
        if choice != .meta, let key = Config.value("GROQ_API_KEY") { return Brain(provider: .groq, apiKey: key) }
        if choice == .meta, let key = Config.value("META_API_KEY") ?? Config.value("MODEL_API_KEY") {
            return Brain(provider: .meta, apiKey: key)
        }
        return nil
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
        \(screen.prefix(120).map { String($0.prefix(90)) }.joined(separator: "\n"))

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
        \(selectedText.isEmpty ? "No text is selected." : "Text they selected:\n\"\"\"\n\(selectedText.prefix(12_000))\n\"\"\"")
        \(selectedText.isEmpty && !screenText.isEmpty ? "Text visible on their screen:\n\(screenText.prefix(150).map { String($0.prefix(90)) }.joined(separator: "\n"))" : "")
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

    /// One chat completion on the first model that isn't rate-limited.
    func generate(_ prompt: String, json: Bool = true, image: Data? = nil) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let image {
            content.insert(["type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]], at: 0)
        }
        var lastError: Error = Failure.empty
        for model in models(forImage: image != nil) {
            var body: [String: Any] = [
                "model": model,
                "messages": [["role": "user", "content": content]],
                "max_completion_tokens": 2500,
            ]
            switch (provider, model.hasPrefix("qwen/")) {
            case (.groq, true): body["reasoning_effort"] = "none"  // Qwen can skip reasoning entirely
            case (.groq, false): body["reasoning_effort"] = "low"; body["include_reasoning"] = false
            case (.meta, _): body["reasoning_effort"] = "low"      // Muse Spark always reasons
            }
            if json { body["response_format"] = ["type": "json_object"] }
            do {
                return try await send(body, model: model)
            } catch Failure.http(let code, let text) where code == 429 || code >= 500 {
                log("brain \(model) unavailable (\(code)); trying next")
                lastError = Failure.http(code, text)
            }
        }
        throw lastError
    }

    private func send(_ body: [String: Any], model: String) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 0..<2 {
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            // Per-minute limits clear quickly; wait once if the server says it's short.
            if status == 429, attempt == 0,
               let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init), wait <= 3 {
                try await Task.sleep(for: .seconds(wait + 0.2)); continue
            }
            guard status == 200 else { throw Failure.http(status, String(decoding: data, as: UTF8.self)) }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            let text = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usage = json?["usage"] as? [String: Any]
            log(String(format: "brain %@: %.1fs, %@ in / %@ out", model, Date().timeIntervalSince(started),
                       "\(usage?["prompt_tokens"] ?? "?")", "\(usage?["completion_tokens"] ?? "?")"))
            guard !text.isEmpty else { throw Failure.empty }
            return Self.stripFences(text)
        }
        throw Failure.http(429, "rate limited")
    }

    /// Models sometimes wrap JSON in ``` fences even in JSON mode.
    private static func stripFences(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
