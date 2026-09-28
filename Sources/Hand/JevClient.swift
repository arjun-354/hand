import Foundation

/// Minimal client for TypeSafe's System One endpoint (https://docs.typesafe.ai/api).
struct JevClient {
    let apiKey: String
    var model = "jev-latest"
    private let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    struct Answer: Decodable {
        let type: String
        let choice: String?
        let score: Double?
        let noul: Double?
        let confidence: Double?
        let probabilities: [String: Double]?
    }

    private struct Response: Decodable {
        let model: String
        let answers: [String: Answer]
    }

    enum Failure: Error, CustomStringConvertible {
        case http(Int, String)
        var description: String {
            switch self {
            case .http(401, _): "TypeSafe rejected the API key"
            case .http(429, _): "TypeSafe rate limit hit"
            case .http(let code, _): "TypeSafe error \(code)"
            }
        }
    }

    /// `questions` is the raw question map from the API docs, keyed by your own ids.
    func ask(state: Any, questions: [String: Any]) async throws -> [String: Answer] {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "state": state,
            "model": model,
            "questions": questions,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.http(status, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data).answers
    }

    /// Reads TYPESAFE_API_KEY from the environment, then from ~/.config/hand/.env.
    static func fromConfig() -> JevClient? {
        Config.value("TYPESAFE_API_KEY").map { JevClient(apiKey: $0) }
    }
}
