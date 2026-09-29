import AppKit

/// Runs a spoken goal to completion: pick the app, then loop
/// read screen → ask Jev for the next step → point and act.
@MainActor
final class Agent {
    let jev: JevClient
    /// Optional planner/writer; Hand works without it.
    let brain: Brain? = Brain.fromConfig()
    private var plan = Brain.Plan()
    /// The first plan keeps running in the background after Hand starts acting.
    private var planning: Task<Void, Never>?
    let apps: [InstalledApp]
    let onStep: (String) -> Void
    /// Screen read taken when the talk key went down.
    let prefetched: (pid: pid_t, snapshot: Task<ScreenSnapshot, Never>)?
    /// What was on screen when the talk key went down ("this").
    let source: SourceContext
    /// Screenshot of that window; sent to Brain only when the request is about it.
    let image: Task<Data?, Never>?
    /// What Brain picked after looking at the image ("Holocene Bon Iver").
    private var imageChoice: String?
    private var looking: Task<Void, Never>?
    private var lookFailed = false
    /// Apps already relaunched for accessibility this session; never do it twice.
    private static var relaunchedApps: Set<String> = []

    let maxSteps = 8
    let minConfidence = 0.25
    let doneThreshold = 0.6

    init(jev: JevClient, apps: [InstalledApp],
         prefetched: (pid: pid_t, snapshot: Task<ScreenSnapshot, Never>)? = nil,
         source: SourceContext = SourceContext(),
         image: Task<Data?, Never>? = nil,
         onStep: @escaping (String) -> Void) {
        self.image = image
        self.source = source
        self.jev = jev
        self.apps = apps
        self.prefetched = prefetched
        self.onStep = onStep
    }

    func run(_ goal: String) async throws -> Phase {
        let front = NSWorkspace.shared.frontmostApplication
        let aboutImage = Self.refersToScreen(goal)
        if aboutImage, let brain, let image {
            looking = Task {
                guard let jpeg = await image.value else { log("no window image to look at"); self.lookFailed = true; return }
                let started = Date()
                do {
                    let choice = try await brain.choose(for: goal, image: jpeg)
                    self.imageChoice = choice.value
                    log(String(format: "looked at image (%.1fs, %dKB): %@ — %@", Date().timeIntervalSince(started),
                               jpeg.count / 1024, choice.value, choice.why))
                } catch {
                    log("image look failed: \(error)")
                    self.lookFailed = true
                }
            }
        }

        // 1. Route: what kind of request, and which app.
        var appOptions: [String: Any] = [
            "current": "The app already in front (\(front?.localizedName ?? "none"))",
            "none": "No particular app",
        ]
        for app in apps.prefix(250) { appOptions[app.name] = NSNull() }

        let route = try await jev.ask(
            state: ["spoken_request": goal, "frontmost_app": front?.localizedName ?? "",
                    "user_was_looking_at": source.summary],
            questions: [
                "intent": [
                    "type": "choice",
                    "instructions": "What does the user want the computer to do? The text is a speech-to-text transcript and may contain misheard words.",
                    "criteria": [
                        "open_app": "Only open, launch, or switch to an application — nothing else",
                        "quit_app": "Quit or close an application",
                        "operate": "Do something inside an application: search, play, click, navigate to a page or setting, type, send, etc.",
                        "slack": "Asks about their Slack: messages someone sent, DMs, mentions, what they missed, or what was said in a channel",
                        "ask": "Asks a question, or wants something summarized, explained, translated, or read out from the screen or the selected text — answered in words, no clicking",
                        "other": "Chit-chat that doesn't ask the computer to do anything",
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

        if intent == "slack" {
            guard let brain else { return .failed("Add a GROQ_API_KEY to read Slack") }
            return await readSlack(goal, with: brain)
        }
        if intent == "ask" || intent == "other" || (route["intent"]?.confidence ?? 0) < minConfidence {
            guard let brain else { return .failed("Add a GROQ_API_KEY to answer questions") }
            return await answer(goal, with: brain)
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
        var replanned = false
        var replanAfterResults = false
        var wroteText = false  // written (not searched) text is in; typing again would duplicate it
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

            // Brain plans in parallel with Jev's first look; Hand only waits for it
            // when Jev isn't confident on its own or text has to be written.
            if step == 1, let looking {
                onStep("Looking at the image…")
                await looking.value
                self.looking = nil
                // Guessing without the picture (e.g. playing anything named "vibe") is worse than stopping.
                if lookFailed || imageChoice == nil { return .failed("Couldn't look at the image — try again") }
            }
            if replanAfterResults, let brain {
                replanAfterResults = false
                onStep("Reading results…")
                if let fresh = try? await makePlan(brain, goal: goal, screen: screen, history: history) { plan = fresh }
            }
            if step == 1, let brain {
                let snapshot = screen, done = history
                planning = Task {
                    if let fresh = try? await self.makePlan(brain, goal: goal, screen: snapshot, history: done) { self.plan = fresh }
                }
            }

            var state: [String: Any] = [
                "goal": goal,
                "app": screen.appName,
                "window": screen.windowTitle,
                "steps_done": history.isEmpty ? ["nothing yet"] : history,
                "user_was_looking_at": source.summary,
                "screen": screen.elements.map { "\($0.id): \($0.summary)" },
            ]
            if !plan.steps.isEmpty { state["plan"] = plan.steps }
            if let imageChoice { state["chosen_from_the_image"] = imageChoice }
            var answers = try await jev.ask(state: state, questions: questions(for: screen, spans: spans))
            // Wait for the plan only when Jev isn't sure of a click, or text is about to be typed
            // (the plan is what writes it). Otherwise act now and use the plan once it lands.
            if let planning, plan.steps.isEmpty {
                let action = answers["action"]?.choice
                let sureClick = action == "click" && (answers["action"]?.confidence ?? 0) >= 0.8
                    && (answers["target"]?.confidence ?? 0) >= 0.8
                if sureClick {
                    log("  jev confident; acting while the plan finishes")
                } else {
                    onStep("Thinking…")
                    await planning.value
                    self.planning = nil
                    if !plan.steps.isEmpty {
                        state["plan"] = plan.steps
                        answers = try await jev.ask(state: state, questions: questions(for: screen, spans: spans))
                    }
                }
            }

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
                if let brain, !replanned {
                    replanned = true
                    unsureSteps = 0
                    onStep("Rethinking…")
                    if let fresh = try? await makePlan(brain, goal: goal, screen: screen, history: history) { plan = fresh }
                    continue
                }
                return .failed("Not sure how to do that")
            }

            if done >= doneThreshold {
                return .done(history.last ?? "Done")
            }

            switch action {
            case "type":
                var text = (answers["text"]?.choice ?? goal).trimmingCharacters(in: .whitespacesAndNewlines)
                // Words lifted from the request are an echo, not a written message: use the planner's text.
                if let chosen = imageChoice, spans.contains(text) || text == plan.texts.first {
                    log("  using what Brain picked from the image instead of \"\(text)\"")
                    text = chosen
                } else if let written = plan.texts.first(where: { !$0.isEmpty }), spans.contains(text) {
                    log("  using planner text instead of \"\(text)\"")
                    text = written.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if brain != nil, spans.contains(text), text.split(separator: " ").count >= 4 {
                    // A long chunk of the request is a writing job, and the writer didn't answer.
                    // Typing the command itself would be wrong, so stop.
                    log("  no planner text for \"\(text)\"; not echoing the request")
                    return .failed("Couldn’t write that — try again")
                }
                let field = answers["field"]?.choice.flatMap(screen.element)
                if let field, let owner = Input.owner(at: field.center), owner != app.processIdentifier, owner != getpid() {
                    log("  field \(field.label) is covered by another app's window (pid \(owner)); not typing")
                    return .failed("Something is covering \(screen.appName)")
                }
                if wroteText, !(field.map(Self.isSearchBox) ?? false) {
                    log("  already wrote the text; not typing it again")
                    return .done(history.last ?? "Done")
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    return .failed("\(screen.appName) lost focus; stopped")
                }
                // In a chat box, Return sends: a line break in pasted text would send it.
                if Self.isMessageBox(field) && !Self.asksToSend(goal) { text = text.replacingOccurrences(of: "\n", with: " ") }
                let stepKey = "type:\(text)"
                if stepKey == lastStep {  // already typed it; submit instead of retyping
                    onStep("Pressing Return")
                    Input.pressReturn()
                    history.append("Pressed Return")
                    lastStep = "submit"
                    break
                }
                onStep("Typing \(text)")
                lastTypedIntoChat = Self.isMessageBox(field)
                let result = await Input.type(text, into: field)
                log("  typed \"\(text)\" result=\(result)")
                if result == .refused { return .failed("Won't type into a secrets file") }
                history.append(result != .failed
                    ? "Typed \"\(text)\" into \(field?.summary ?? "the focused field")"
                    : "Tried to type \"\(text)\" but the field stayed empty")
                lastStep = stepKey
                if result != .failed, !(field.map(Self.isSearchBox) ?? false), text.split(separator: " ").count >= 4 {
                    wroteText = true
                }
                // A search box always wants Return next; don't leave it to a guess at the suggestions list.
                if result != .failed, let field, Self.isSearchBox(field) {
                    try await Task.sleep(for: .seconds(0.3))
                    Input.pressReturn()
                    log("  pressed Return to search")
                    history.append("Pressed Return to search")
                    lastStep = "submit"
                    replanAfterResults = brain != nil  // the plan was written before results existed
                }

            case "submit":
                onStep("Pressing Return")
                Input.pressReturn()
                history.append("Pressed Return")
                lastStep = "submit"

            default:
                guard let id = answers["target"]?.choice, let element = screen.element(id),
                      (answers["target"]?.confidence ?? 0) >= minConfidence else {
                    return .failed("Not sure what to click")
                }
                let stepKey = "click:\(element.summary)"
                // Wanting the same click again usually means it already worked, but only
                // trust that when Jev also leans toward done; otherwise it's stuck.
                if stepKey == lastStep {
                    if done >= 0.4 { return .done(history.last ?? "Done") }
                    return .failed("Got stuck on \(element.label)")
                }
                // Screenshot positions can go stale; never click outside the app.
                if element.ax == nil, !Self.isInside(element.center, windowsOf: app) {
                    log("  \(element.label) @\(Int(element.center.x)),\(Int(element.center.y)) is outside \(screen.appName)'s windows; looking again")
                    try await Task.sleep(for: .seconds(0.4))
                    continue
                }
                if let owner = Input.owner(at: element.center), owner != app.processIdentifier, owner != getpid() {
                    log("  \(element.label) is covered by another app's window (pid \(owner)); not clicking")
                    return .failed("Something is covering \(screen.appName)")
                }
                if !Self.asksToSend(goal), element.label.range(of: #"\bsend\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    return .done("Draft ready — say “send” to send it")
                }
                onStep("Clicking \(element.label)")
                Input.click(element)
                history.append("Clicked \(element.summary)")
                lastStep = stepKey
            }

            try await Task.sleep(for: .seconds(1.0))  // let the UI settle
        }

        planning?.cancel()
        return .failed("Ran out of steps")
    }

    private func questions(for screen: ScreenSnapshot, spans: [String]) -> [String: Any] {
        var targets: [String: Any] = [:]
        for e in screen.elements { targets[e.id] = e.summary }

        var fields: [String: Any] = ["focused": "Whatever field currently has keyboard focus"]
        for e in screen.elements where e.isTextInput { fields[e.id] = e.summary }

        var texts: [String: Any] = [:]
        for s in spans { texts[s] = NSNull() }
        for (value, meaning) in source.typeableValues { texts[value] = meaning }
        if let imageChoice { texts[imageChoice] = "What to search for or type, chosen by looking at the user's screen" }
        for text in plan.texts.prefix(5) where !text.isEmpty { texts[String(text.prefix(1000))] = "Text written for this task by the planner" }

        return [
            "done": [
                "type": "noul",
                // Picked by testing phrasings against recorded screens; separates done/not-done best.
                "instructions": "Does the `window` title or the last entry of `steps_done` show that the `goal` has been achieved?",
            ],
            "action": [
                "type": "choice",
                "instructions": "What is the single best next step toward the `goal`, given `steps_done`, the `plan` if there is one, and what is on `screen`?",
                "criteria": [
                    "click": "Click an item on screen: a button, list item, link, tab, sidebar entry, or search result",
                    "type": "Type or paste text into a search box, text field, title, or page that doesn't already contain it. Only when the goal asks to search for, play, find, write, add, or save something specific",
                    "submit": "Press Return to submit text that was just typed",
                ],
            ],
            "target": [
                "type": "choice",
                "instructions": "Which item on `screen` should be clicked next to move toward the `goal`? If there is a `plan`, follow its next step not yet in `steps_done`. Items with the same name are told apart by the section in brackets; pick the one in the section the goal names. Tags and headers name a section, they don't add to it.",
                "criteria": targets,
            ],
            "field": [
                "type": "choice",
                "instructions": "Which text field or search box should text be typed into to move toward the `goal`?",
                "criteria": fields,
            ],
            "text": [
                "type": "choice",
                "instructions": "What should be typed to move toward the `goal`? Prefer text the planner wrote when the `plan` calls for typing. Otherwise words from the `goal` (leave out the app name and command words like play, open, search), or, when the goal refers to 'this', 'the link', or what the user was looking at, the matching value from `user_was_looking_at`.",
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
                if let windows = ScreenReader.attr(root, "AXWindows") as? [AXUIElement], let window = windows.first {
                    await waitUntilStill(window)
                    return true
                }
            }
            try? await Task.sleep(for: .seconds(0.1))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier
    }

    private func readSlack(_ question: String, with brain: Brain) async -> Phase {
        guard let slack = Slack.fromKeychain() else { return .failed("Connect Slack first: scripts/slack-token.sh") }
        let started = Date()
        do {
            onStep("Checking Slack…")
            let lookup = try await brain.slackLookup(for: question)
            var messages: [Slack.Message]
            switch lookup.kind {
            case "dms":
                messages = try await slack.recentDMs(hours: Double(lookup.days) * 24)
                if !lookup.person.isEmpty {
                    let who = lookup.person.lowercased()
                    messages = messages.filter { $0.author.lowercased().contains(who) || $0.channel.lowercased().contains(who) }
                }
            case "mentions":
                messages = try await slack.mentions(days: lookup.days)
            default:
                var query = [lookup.words, "after:\(Slack.day(daysAgo: lookup.days + 1))"]
                if !lookup.channel.isEmpty { query.append("in:#\(lookup.channel)") }
                if !lookup.person.isEmpty {
                    guard let id = try await slack.person(named: lookup.person) else {
                        return .failed("Couldn't find \(lookup.person) on Slack")
                    }
                    query.append("from:<@\(id)>")
                }
                messages = try await slack.search(query.filter { !$0.isEmpty }.joined(separator: " "))
            }
            log(String(format: "slack %@ words=%@ person=%@ channel=%@ days=%d -> %d messages (%.1fs)", lookup.kind,
                       lookup.words, lookup.person, lookup.channel, lookup.days, messages.count, Date().timeIntervalSince(started)))
            onStep("Reading \(messages.count) messages…")
            let text = try await brain.summarize(question: question, source: "Slack", messages: messages.map(\.line))
            log(String(format: "slack answer ready in %.1fs", Date().timeIntervalSince(started)))
            return .answer(text)
        } catch {
            log("slack failed: \(error)")
            return .failed("\(error)")
        }
    }

    private func answer(_ question: String, with brain: Brain) async -> Phase {
        onStep("Reading…")
        var selected = source.selectedText
        let secret = Redact.isSecretWindow(source.windowTitle)
        if selected.isEmpty, !secret, NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
            selected = Redact.secrets(await Input.copySelection())
        }
        var screenText: [String] = []
        if selected.isEmpty, !secret, let prefetched { screenText = await prefetched.snapshot.value.elements.map(\.label) }
        onStep("Thinking…")
        let started = Date()
        do {
            let jpeg = Self.refersToScreen(question) ? await image?.value : nil
            let text = try await brain.answer(question: question, selectedText: selected,
                                               lookingAt: source.summary, screenText: jpeg == nil ? screenText : [],
                                               image: jpeg)
            log(String(format: "answer (%.1fs, %d chars selected, %d screen items): %@", Date().timeIntervalSince(started),
                       selected.count, screenText.count, String(text.prefix(120))))
            return text.isEmpty ? .failed("No answer") : .answer(text)
        } catch {
            log("answer failed: \(error)")
            return .failed("Couldn’t reach the Brain")
        }
    }

    private func makePlan(_ brain: Brain, goal: String, screen: ScreenSnapshot?, history: [String]) async throws -> Brain.Plan? {
        let started = Date()
        do {
            let plan = try await brain.plan(
                goal: goal, app: screen?.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
                window: screen?.windowTitle ?? "", screen: screen?.elements.map(\.summary) ?? [],
                lookingAt: source.summary.merging(imageChoice.map { ["chosen_from_the_image": $0] } ?? [:]) { a, _ in a },
                stepsDone: history)
            log(String(format: "plan (%.1fs): %@ texts=%@ answer=%@", Date().timeIntervalSince(started),
                       plan.steps.joined(separator: " → "), plan.texts.description, plan.answer ?? "-"))
            return plan
        } catch {
            if !Task.isCancelled { log("plan failed: \(error)") }
            return nil
        }
    }

    static func isSearchBox(_ element: UIElement) -> Bool {
        if element.role == "AXSearchField" { return true }
        let l = element.label.lowercased()
        return ["search", "what do you want to play", "find"].contains { l.contains($0) }
    }

    /// Requests about the picture/screen itself, the only time a screenshot leaves the Mac.
    static func refersToScreen(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return ["image", "picture", "photo", "pic ", "screenshot", "my screen", "on screen", "on my screen",
                "this video", "thumbnail", "this design", "vibe of this", "looks like"].contains { g.contains($0) }
    }

    /// Words that mean the user actually wants something sent.
    static func asksToSend(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return ["send", "message", "reply", "text ", "tell ", "post", "tweet", "email"].contains { g.contains($0) }
    }

    /// Text areas and fields that look like a chat composer, where Return sends.
    static func isMessageBox(_ element: UIElement?) -> Bool {
        guard let element else { return false }
        let l = element.label.lowercased()
        return ["message", "reply", "chat", "write", "ask", "compose", "prompt", "type a", "how can i help"].contains { l.contains($0) }
    }

    /// Windows animate open; screenshot positions are wrong until they stop moving.
    private func waitUntilStill(_ window: AXUIElement) async {
        var last = ScreenReader.frame(of: window)
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(0.15))
            let now = ScreenReader.frame(of: window)
            if now == last { break }
            last = now
        }
        try? await Task.sleep(for: .seconds(0.2))
    }

    /// True when `point` lands on one of `app`'s windows, so a click can't hit another app.
    static func isInside(_ point: CGPoint, windowsOf app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (ScreenReader.attr(root, "AXWindows") as? [AXUIElement]) ?? []
        return windows.contains { ScreenReader.frame(of: $0)?.contains(point) ?? false }
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
