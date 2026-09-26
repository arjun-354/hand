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
            isDown = true
            onPress()
        } else if !pressed && isDown {
            isDown = false
            onRelease()
        }
    }
}
