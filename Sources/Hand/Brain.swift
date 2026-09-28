import Foundation

/// The slow, smart half of Hand, backed by Meta's Model API (Muse Spark,
/// OpenAI-compatible chat completions). Plans multi-step tasks, writes text, answers
/// questions and looks at images. Jev still makes every per-step decision.
struct Brain {
    let apiKey: String
    /// muse-spark-1.3 is Meta's recommended model and reads images. The "-contributor"
    /// variants are cheaper but Meta may train on what's sent, which here includes screen text.
    var model = Config.value("META_MODEL") ?? "muse-spark-1.3"
    private static let endpoint = URL(string: "https://api.meta.ai/v1/chat/completions")!

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
            case .http(401, _): "Meta rejected the API key"
            case .http(429, _): "Meta rate limit hit"
            case .http(let code, let body): "Meta error \(code): \(body.prefix(200))"
            case .empty: "Meta returned nothing"
            }
        }
    }

    static func fromConfig() -> Brain? {
        (Config.value("META_API_KEY") ?? Config.value("MODEL_API_KEY")).map { Brain(apiKey: $0) }
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

    /// One chat completion. Muse Spark always reasons; "low" keeps it quick.
    func generate(_ prompt: String, json: Bool = true, image: Data? = nil) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let image {
            content.insert(["type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())", "detail": "low"]], at: 0)
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "reasoning_effort": "low",
            "max_completion_tokens": 4000,
        ]
        if json { body["response_format"] = ["type": "json_object"] }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Rate limits are per minute; one short backoff covers a burst.
        for attempt in 0..<2 {
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 && attempt == 0 { try await Task.sleep(for: .milliseconds(700)); continue }
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
