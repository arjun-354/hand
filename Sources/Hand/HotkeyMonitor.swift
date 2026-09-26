import AppKit

/// Push-to-talk key. Hold to listen, release to run.
enum TalkKey {
    case rightOption
    case rightCommand
    case rightControl
    case fn

    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .fn: .function
        }
    }
}

/// Watches modifier-key presses system-wide. Global monitoring needs the
/// Accessibility permission (System Settings → Privacy & Security → Accessibility).
final class HotkeyMonitor {
    private let key: TalkKey
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var monitors: [Any] = []
    private var isDown = false
    private var watchdog: Timer?
    private var pressedAt = Date()
    /// Listening stops on its own after this long, even if the key still reads as held.
    private let maxHold: TimeInterval = 20

    init(key: TalkKey, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.key = key
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == key.keyCode else { return }
        let pressed = event.modifierFlags.contains(key.flag)
        if pressed && !isDown {
            press()
        } else if !pressed && isDown {
            release()
        }
    }

    private func press() {
        isDown = true
        pressedAt = Date()
        onPress()
        // Key-up events can get lost (secure input, other modifiers). Poll the real
        // key state so Hand never gets stuck listening.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isDown else { return }
            let held = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(self.key.keyCode))
            if !held || Date().timeIntervalSince(self.pressedAt) > self.maxHold { self.release() }
        }
    }

    private func release() {
        watchdog?.invalidate()
        watchdog = nil
        guard isDown else { return }
        isDown = false
        onRelease()
    }
}
