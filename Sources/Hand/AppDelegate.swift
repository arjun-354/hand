import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = HandState()
    private var panel: NotchPanel?
    private var hotkey: HotkeyMonitor?
    private var statusItem: NSStatusItem?

    func applicationWillTerminate(_ notification: Notification) {
        log("quitting normally")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fatal errors print to stderr, which goes nowhere for an app opened from Finder.
        freopen(Log.dir.appendingPathComponent("stderr.log").path, "a", stderr)
        let panel = NotchPanel(state: state)
        panel.orderFrontRegardless()
        self.panel = panel

        hotkey = HotkeyMonitor(
            key: .rightOption,
            // Called synchronously on the main thread so press and release can never run out of order.
            onPress: { [state] in MainActor.assumeIsolated { state.startListening() } },
            onRelease: { [state] in MainActor.assumeIsolated { state.stopListening() } }
        )
        hotkey?.start()

        setUpStatusItem()
        requestAccessibilityIfNeeded()
        if !ScreenVision.hasPermission { ScreenVision.requestPermission() }
        ScreenVision.warmUp()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panel?.place(on: NotchPanel.targetScreen()) }
        }

        handleDebugArguments()
    }

    /// Small menu bar icon so there's a way to quit and replay the animation.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Hand")
        let menu = NSMenu()
        menu.addItem(withTitle: "Hold Right ⌥ to talk", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Play demo", action: #selector(playDemo), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Accessibility settings…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func playDemo() { runDemo() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func runDemo() { state.playDemo() }

    /// --demo: play the animation. --say "text": run a command as if spoken.
    /// --axdump <bundle-id>: write what Hand can see in that app to ~/Library/Logs/Hand/axdump.txt.
    private func handleDebugArguments() {
        let args = CommandLine.arguments
        if args.contains("--demo") { runDemo() }
        if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
            let text = args[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await state.run(text)
            }
        }
        if let i = args.firstIndex(of: "--context"), i + 1 < args.count,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first {
            let ctx = SourceContext.capture(pid: app.processIdentifier, appName: app.localizedName ?? "")
            Log.write("app: \(ctx.appName)\ntitle: \(ctx.windowTitle)\nlink: \(ctx.link)\nselected: \(ctx.selectedText)\nclipboard: \(ctx.clipboard.prefix(80))",
                      to: "context.txt")
        }
        if let i = args.firstIndex(of: "--axtree"), i + 1 < args.count {
            let bundleID = args[i + 1]
            Task { @MainActor in
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .seconds(2))
                var lines: [String] = []
                func walk(_ e: AXUIElement, _ d: Int) {
                    guard d < 30, lines.count < 600 else { return }
                    let kids = (ScreenReader.attr(e, "AXChildren") as? [AXUIElement]) ?? []
                    let label = [ScreenReader.string(e, "AXTitle"), ScreenReader.string(e, "AXDescription"), ScreenReader.string(e, "AXValue")].filter { !$0.isEmpty }.joined(separator: " | ")
                    lines.append(String(repeating: "  ", count: d) + ScreenReader.string(e, "AXRole") + " (\(kids.count)) " + String(label.prefix(60)) + " " + ScreenReader.actionNames(e).joined(separator: ","))
                    kids.forEach { walk($0, d + 1) }
                }
                walk(root, 0)
                Log.write(lines.joined(separator: "\n"), to: "axtree.txt")
            }
        }
        if let i = args.firstIndex(of: "--axdump"), i + 1 < args.count {
            let bundleID = args[i + 1]
            Task { @MainActor in
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                    Log.write("\(bundleID) is not running", to: "axdump.txt"); return
                }
                let screen = await ScreenReader.snapshot(of: app)
                let lines = ["trusted: \(AXIsProcessTrusted())", "\(screen.appName) — \(screen.windowTitle) — \(screen.elements.count) elements"]
                    + screen.elements.map { "\($0.id): \($0.summary)  @\(Int($0.frame.midX)),\(Int($0.frame.midY))" }
                Log.write(lines.joined(separator: "\n"), to: "axdump.txt")
            }
        }
    }
}
