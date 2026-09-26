import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = HandState()
    private var panel: NotchPanel?
    private var hotkey: HotkeyMonitor?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = NotchPanel(state: state)
        panel.orderFrontRegardless()
        self.panel = panel

        hotkey = HotkeyMonitor(
            key: .rightOption,
            onPress: { [state] in Task { @MainActor in state.startListening() } },
            onRelease: { [state] in Task { @MainActor in state.stopListening() } }
        )
        hotkey?.start()

        setUpStatusItem()
        requestAccessibilityIfNeeded()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panel?.place(on: NotchPanel.targetScreen()) }
        }

        if CommandLine.arguments.contains("--demo") { runDemo() }
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
}
