import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Low-level mouse and keyboard control. Requires the Accessibility permission.
@MainActor
enum Input {
    /// Presses an element: AXPress when the element supports it, a real click otherwise.
    static func click(_ element: UIElement) {
        let rowLike = ["AXRow", "AXCell", "AXOutlineRow"].contains(element.role)
        if element.canPress, !rowLike,
           AXUIElementPerformAction(element.ax, "AXPress" as CFString) == .success {
            return
        }
        mouseClick(at: element.center)
    }

    static func mouseClick(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(type == .mouseMoved ? 30_000 : 15_000)
        }
    }

    /// Focuses a text input, clears it and types `text`.
    static func type(_ text: String, into element: UIElement?) async {
        if let element {
            AXUIElementSetAttributeValue(element.ax, "AXFocused" as CFString, kCFBooleanTrue)
            mouseClick(at: element.center)
            try? await Task.sleep(for: .seconds(0.15))
            key(kVK_ANSI_A, flags: .maskCommand)  // select existing text so typing replaces it
        }
        typeString(text)
    }

    static func typeString(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for chunk in text.chunked(into: 16) {
            let utf16 = Array(chunk.utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event?.post(tap: .cghidEventTap)
            }
            usleep(12_000)
        }
    }

    static func key(_ code: Int, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }

    static func pressReturn() { key(kVK_Return) }
    static func pressEscape() { key(kVK_Escape) }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }
    }
}
