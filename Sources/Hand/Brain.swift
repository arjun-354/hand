import Foundation

enum Command {
    case open(InstalledApp)
    case quit(InstalledApp)
    case unsure(String)
}

/// Turns a spoken sentence into a Command. Uses Jev when a key is configured,
/// otherwise a simple keyword matcher so the pipeline still works offline.
struct Brain {
    let jev: JevClient?
    let apps: [InstalledApp]

    /// Below this, Hand says it's not sure instead of acting.
    let minConfidence = 0.5

    func decide(_ transcript: String) async throws -> Command {
        if let jev { return try await decideWithJev(transcript, jev) }
        return decideLocally(transcript)
    }

    // One call, all questions evaluated in parallel (speculative fan-out).
    private func decideWithJev(_ transcript: String, _ jev: JevClient) async throws -> Command {
        var appOptions: [String: Any] = [:]
        for app in apps.prefix(254) { appOptions[app.name] = NSNull() }
        appOptions["none"] = "No installed app is mentioned"

        let answers = try await jev.ask(
            state: ["spoken_request": transcript],
            questions: [
                "intent": [
                    "type": "choice",
                    "instructions": "What does the user want the computer to do? The text is a speech-to-text transcript and may contain misheard words.",
                    "criteria": [
                        "open_app": "Open, launch, start, bring up, or switch to an application",
                        "quit_app": "Quit, close, or kill an application",
                        "other": "Anything else",
                    ],
                ],
                "app": [
                    "type": "choice",
                    "instructions": "Which installed application is the user referring to? Account for speech-to-text mistakes (e.g. 'spot a fie' means Spotify).",
                    "criteria": appOptions,
                ],
            ]
        )

        guard let intent = answers["intent"], let appAnswer = answers["app"],
              let intentChoice = intent.choice, let appName = appAnswer.choice else {
            return .unsure("Didn't get that")
        }
        log("jev intent=\(intentChoice) (\(fmt(intent.confidence))) app=\(appName) (\(fmt(appAnswer.confidence)))")

        guard (intent.confidence ?? 0) >= minConfidence else { return .unsure("Not sure what to do") }
        guard intentChoice != "other" else { return .unsure("I can only open and quit apps for now") }
        guard appName != "none", (appAnswer.confidence ?? 0) >= minConfidence,
              let app = apps.first(where: { $0.name == appName }) else {
            return .unsure("Which app?")
        }
        return intentChoice == "quit_app" ? .quit(app) : .open(app)
    }

    private func decideLocally(_ transcript: String) -> Command {
        let text = transcript.lowercased()
        let quitWords = ["quit", "close", "kill", "exit"]
        let wantsQuit = quitWords.contains { text.contains($0) }
        let squashed = text.filter(\.isLetter)

        // Longest name first so "Google Chrome" wins over "Chrome"-like substrings.
        let match = apps
            .sorted { $0.name.count > $1.name.count }
            .first { squashed.contains($0.name.lowercased().filter(\.isLetter)) }

        guard let match else { return .unsure("Which app?") }
        return wantsQuit ? .quit(match) : .open(match)
    }

    private func fmt(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "-" }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[hand] \(message)\n".utf8))
}
