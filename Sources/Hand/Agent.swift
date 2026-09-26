import AppKit

/// Runs a spoken goal to completion: pick the app, then loop
/// read screen → ask Jev for the next step → point and act.
@MainActor
final class Agent {
    let jev: JevClient
    let apps: [InstalledApp]
    let pointer: Pointer
    let onStep: (String) -> Void
    /// Screen read taken when the talk key went down.
    let prefetched: (pid: pid_t, snapshot: Task<ScreenSnapshot, Never>)?
    /// Apps already relaunched for accessibility this session; never do it twice.
    private static var relaunchedApps: Set<String> = []

    let maxSteps = 8
    let minConfidence = 0.25
    let doneThreshold = 0.6

    init(jev: JevClient, apps: [InstalledApp], pointer: Pointer,
         prefetched: (pid: pid_t, snapshot: Task<ScreenSnapshot, Never>)? = nil,
         onStep: @escaping (String) -> Void) {
        self.jev = jev
        self.apps = apps
        self.pointer = pointer
        self.prefetched = prefetched
        self.onStep = onStep
    }

    func run(_ goal: String) async throws -> Phase {
        let front = NSWorkspace.shared.frontmostApplication

        // 1. Route: what kind of request, and which app.
        var appOptions: [String: Any] = [
            "current": "The app already in front (\(front?.localizedName ?? "none"))",
            "none": "No particular app",
        ]
        for app in apps.prefix(250) { appOptions[app.name] = NSNull() }

        let route = try await jev.ask(
            state: ["spoken_request": goal, "frontmost_app": front?.localizedName ?? ""],
            questions: [
                "intent": [
                    "type": "choice",
                    "instructions": "What does the user want the computer to do? The text is a speech-to-text transcript and may contain misheard words.",
                    "criteria": [
                        "open_app": "Only open, launch, or switch to an application — nothing else",
                        "quit_app": "Quit or close an application",
                        "operate": "Do something inside an application: search, play, click, navigate to a page or setting, type, send, etc.",
                        "other": "A question or chit-chat that doesn't ask the computer to do anything",
                    ],
                ],
                "app": [
                    "type": "choice",
                    "instructions": "Which application is needed for this request? Account for speech-to-text mistakes. Settings means System Settings.",
                    "criteria": appOptions,
                ],
            ]
        )
        let intent = route["intent"]?.choice ?? "other"
        let appChoice = route["app"]?.choice ?? "none"
        log("route intent=\(intent) (\(fmt(route["intent"]?.confidence))) app=\(appChoice) (\(fmt(route["app"]?.confidence)))")

        guard (route["intent"]?.confidence ?? 0) >= minConfidence, intent != "other" else {
            return .failed("I can only control the Mac for now")
        }

        let target = apps.first { $0.name == appChoice }

        switch intent {
        case "quit_app":
            guard let target else { return .failed("Which app?") }
            return await Actions.run(.quit(target))
        case "open_app":
            guard let target else { return .failed("Which app?") }
            return await Actions.run(.open(target))
        default:
            break
        }

        // 2. Bring the app to the front.
        var history: [String] = []
        if let target, target.url.standardizedFileURL != front?.bundleURL?.standardizedFileURL {
            onStep("Opening \(target.name)")
            guard await bringToFront(target) else { return .failed("Couldn't open \(target.name)") }
            history.append("Opened \(target.name)")
        }

        // 3. Act, one step at a time.
        let spans = Self.spans(of: goal)
        var lastStep = ""
        var relaunched = false
        var lastTypedIntoChat = false
        var unsureSteps = 0
        for step in 1...maxSteps {
            try Task.checkCancellation()
            guard let app = NSWorkspace.shared.frontmostApplication else { break }
            var screen: ScreenSnapshot
            if step == 1, let prefetched, prefetched.pid == app.processIdentifier {
                screen = await prefetched.snapshot.value  // captured while you were talking
            } else {
                screen = await ScreenReader.snapshot(of: app)
            }
            let axCount = screen.elements.filter { $0.ax != nil }.count
            if axCount < 5, !relaunched, await relaunchAccessible(app),
               let fresh = NSWorkspace.shared.frontmostApplication {
                relaunched = true
                screen = await ScreenReader.snapshot(of: fresh)
            }
            log("step \(step): \(screen.appName) \"\(screen.windowTitle)\" \(screen.elements.count) elements")
            dumpScreen(screen)
            guard !screen.elements.isEmpty else {
                if !AXIsProcessTrusted() { return .failed("Allow Accessibility for Hand") }
                if !ScreenVision.hasPermission { return .failed("Allow Screen Recording for Hand") }
                return .failed("Can't see \(screen.appName)'s screen")
            }

            let answers = try await jev.ask(state: [
                "goal": goal,
                "app": screen.appName,
                "window": screen.windowTitle,
                "steps_done": history.isEmpty ? ["nothing yet"] : history,
                "screen": screen.elements.map { "\($0.id): \($0.summary)" },
            ], questions: questions(for: screen, spans: spans))

            let done = answers["done"]?.noul ?? 0
            // Return only makes sense right after typing; otherwise take Jev's best remaining option.
            var probs = answers["action"]?.probabilities ?? [:]
            if !lastStep.hasPrefix("type:") || (lastTypedIntoChat && !Self.asksToSend(goal)) { probs["submit"] = nil }
            let action = probs.max { $0.value < $1.value }?.key ?? "click"
            log("  done=\(fmt(done)) action=\(action) (\(fmt(answers["action"]?.confidence))) target=\(answers["target"]?.choice ?? "-") (\(fmt(answers["target"]?.confidence))) field=\(answers["field"]?.choice ?? "-") text=\(answers["text"]?.choice ?? "-")")

            let actionConfidence = answers["action"]?.confidence ?? 0
            let targetConfidence = answers["target"]?.confidence ?? 0
            unsureSteps = (actionConfidence < 0.5 && targetConfidence < 0.5) ? unsureSteps + 1 : 0
            if unsureSteps >= 2 && done < doneThreshold {
                pointer.hide()
                return .failed("Not sure how to do that")
            }

            if done >= doneThreshold {
                pointer.hide()
                return .done(history.last ?? "Done")
            }

            switch action {
            case "type":
                let text = answers["text"]?.choice ?? goal
                let field = answers["field"]?.choice.flatMap(screen.element)
                let stepKey = "type:\(text)"
                if stepKey == lastStep {  // already typed it; submit instead of retyping
                    onStep("Pressing Return")
                    Input.pressReturn()
                    history.append("Pressed Return")
                    lastStep = "submit"
                    break
                }
                onStep("Typing \(text)")
                if let field { await pointer.move(to: field.center, label: "Type “\(text)”") }
                pointer.clickPulse()
                lastTypedIntoChat = Self.isMessageBox(field)
                let landed = await Input.type(text, into: field)
                log("  typed \"\(text)\" landed=\(landed)")
                history.append(landed
                    ? "Typed \"\(text)\" into \(field?.summary ?? "the focused field")"
                    : "Tried to type \"\(text)\" but the field stayed empty")
                lastStep = stepKey

            case "submit":
                onStep("Pressing Return")
                Input.pressReturn()
                history.append("Pressed Return")
                lastStep = "submit"

            default:
                guard let id = answers["target"]?.choice, let element = screen.element(id),
                      (answers["target"]?.confidence ?? 0) >= minConfidence else {
                    pointer.hide()
                    return .failed("Not sure what to click")
                }
                let stepKey = "click:\(element.summary)"
                guard stepKey != lastStep else {
                    pointer.hide()
                    return .failed("Got stuck on \(element.label)")
                }
                onStep("Clicking \(element.label)")
                await pointer.move(to: element.center, label: element.label)
                pointer.clickPulse()
                Input.click(element)
                history.append("Clicked \(element.summary)")
                lastStep = stepKey
            }

            try await Task.sleep(for: .seconds(1.0))  // let the UI settle
        }

        pointer.hide()
        return .failed("Ran out of steps")
    }

    private func questions(for screen: ScreenSnapshot, spans: [String]) -> [String: Any] {
        var targets: [String: Any] = [:]
        for e in screen.elements { targets[e.id] = e.summary }

        var fields: [String: Any] = ["focused": "Whatever field currently has keyboard focus"]
        for e in screen.elements where e.isTextInput { fields[e.id] = e.summary }

        var texts: [String: Any] = [:]
        for s in spans { texts[s] = NSNull() }

        return [
            "done": [
                "type": "noul",
                // Picked by testing phrasings against recorded screens; separates done/not-done best.
                "instructions": "Does the `window` title or the last entry of `steps_done` show that the `goal` has been achieved?",
            ],
            "action": [
                "type": "choice",
                "instructions": "What is the single best next step toward the `goal`, given `steps_done` and what is on `screen`?",
                "criteria": [
                    "click": "Click an item on screen: a button, list item, link, tab, sidebar entry, or search result",
                    "type": "Type text into a search box or text field that doesn't already contain it. Only when the goal asks to search for, play, find, write, or type something specific",
                    "submit": "Press Return to submit text that was just typed",
                ],
            ],
            "target": [
                "type": "choice",
                "instructions": "Which item on `screen` should be clicked next to move toward the `goal`?",
                "criteria": targets,
            ],
            "field": [
                "type": "choice",
                "instructions": "Which text field or search box should text be typed into to move toward the `goal`?",
                "criteria": fields,
            ],
            "text": [
                "type": "choice",
                "instructions": "Which words from the `goal` should be typed into a search box to find what the user wants? Leave out the app name and command words like play, open, search.",
                "criteria": texts,
            ],
        ]
    }

    /// CEF apps (Spotify) ignore AXManualAccessibility and only expose their UI
    /// when launched with this flag.
    /// Qt apps (CapCut) also bundle CEF, but draw their UI themselves; the flag doesn't help them.
    static func needsAccessibilityFlag(_ url: URL) -> Bool {
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let has = { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
        return has("Chromium Embedded Framework.framework") && !has("QtCore.framework")
    }

    /// Relaunches a CEF app with its accessibility tree switched on.
    private func relaunchAccessible(_ app: NSRunningApplication) async -> Bool {
        guard let url = app.bundleURL, Self.needsAccessibilityFlag(url),
              let bundleID = app.bundleIdentifier, !Self.relaunchedApps.contains(bundleID) else { return false }
        Self.relaunchedApps.insert(bundleID)
        log("relaunching \(app.localizedName ?? "") with --force-renderer-accessibility")
        onStep("Restarting \(app.localizedName ?? "app") so I can see it")
        app.terminate()
        for _ in 0..<50 where !app.isTerminated { try? await Task.sleep(for: .seconds(0.1)) }
        let installed = InstalledApp(name: app.localizedName ?? "", url: url)
        guard await bringToFront(installed) else { return false }
        try? await Task.sleep(for: .seconds(2.5))  // web content loads after the window appears
        return true
    }

    private func bringToFront(_ app: InstalledApp) async -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if Self.needsAccessibilityFlag(app.url) { config.arguments = ["--force-renderer-accessibility"] }
        guard let running = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: config) else {
            return false
        }
        running.activate()
        // Wait for it to be frontmost with a window.
        for _ in 0..<40 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier {
                let root = AXUIElementCreateApplication(running.processIdentifier)
                if let windows = ScreenReader.attr(root, "AXWindows") as? [AXUIElement], !windows.isEmpty {
                    try? await Task.sleep(for: .seconds(0.4))
                    return true
                }
            }
            try? await Task.sleep(for: .seconds(0.1))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier
    }

    /// Words that mean the user actually wants something sent.
    static func asksToSend(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return ["send", "message", "reply", "text ", "tell ", "post", "tweet", "email"].contains { g.contains($0) }
    }

    /// Text areas and fields that look like a chat composer, where Return sends.
    static func isMessageBox(_ element: UIElement?) -> Bool {
        guard let element else { return false }
        if element.role == "AXTextArea" { return true }
        let l = element.label.lowercased()
        return ["message", "reply", "chat", "write", "ask", "compose", "prompt", "type a", "how can i help"].contains { l.contains($0) }
    }

    /// Every run of 1–6 consecutive words, so Jev can pick the part to type.
    static func spans(of text: String) -> [String] {
        let words = text.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for i in words.indices {
            for len in 1...min(6, words.count - i) {
                let span = words[i..<(i + len)].joined(separator: " ")
                if !out.contains(span) { out.append(span) }
            }
        }
        return Array(out.prefix(250))
    }

    private func dumpScreen(_ screen: ScreenSnapshot) {
        let lines = screen.elements.map { "\($0.id): \($0.summary)  @\(Int($0.frame.midX)),\(Int($0.frame.midY))" }
        Log.write(lines.joined(separator: "\n"), to: "last-screen.txt")
    }
}

func fmt(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "-" }
