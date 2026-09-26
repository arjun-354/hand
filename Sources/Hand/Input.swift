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

    /// Focuses a text input, replaces its contents with `text`, and reports whether it landed.
    @discardableResult
    static func type(_ text: String, into element: UIElement?) async -> Bool {
        if let element {
            mouseClick(at: element.center)
            AXUIElementSetAttributeValue(element.ax, "AXFocused" as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .seconds(0.25))
        }
        key(kVK_ANSI_A, flags: .maskCommand)  // select existing text so the paste replaces it
        await paste(text)
        try? await Task.sleep(for: .seconds(0.2))

        guard let element else { return true }
        if ScreenReader.string(element.ax, "AXValue").localizedCaseInsensitiveContains(text) { return true }
        // Paste didn't take: try setting the value directly, then real keystrokes.
        AXUIElementSetAttributeValue(element.ax, "AXValue" as CFString, text as CFString)
        try? await Task.sleep(for: .seconds(0.15))
        if ScreenReader.string(element.ax, "AXValue").localizedCaseInsensitiveContains(text) { return true }
        typeString(text)
        try? await Task.sleep(for: .seconds(0.2))
        return ScreenReader.string(element.ax, "AXValue").localizedCaseInsensitiveContains(text)
    }

    /// Pastes through the clipboard (web views accept this reliably), then restores the clipboard.
    static func paste(_ text: String) async {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        key(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(for: .seconds(0.3))
        board.clearContents()
        let restored = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
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
