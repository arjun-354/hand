import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Low-level mouse and keyboard control. Requires the Accessibility permission.
@MainActor
enum Input {
    /// Presses an element: AXPress when the element supports it, a real click otherwise.
    static func click(_ element: UIElement) {
        let rowLike = ["AXRow", "AXCell", "AXOutlineRow"].contains(element.role)
        if element.canPress, !rowLike, let ax = element.ax,
           AXUIElementPerformAction(ax, "AXPress" as CFString) == .success {
            return
        }
        mouseClick(at: element.center)
    }

    /// The app whose window is actually at `point` (what a click there would hit).
    static func owner(at point: CGPoint) -> pid_t? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func mouseClick(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(type == .mouseMoved ? 30_000 : 15_000)
        }
    }

    /// Title of the window that owns the element at `point` (what a click there would land in).
    static func windowTitle(at point: CGPoint) -> String? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element, let window = ScreenReader.element(element, "AXWindow") else { return nil }
        return ScreenReader.string(window, "AXTitle")
    }

    enum TypeResult { case landed, notVerified, failed, refused }

    /// Puts `text` into a field. Single-line fields (search boxes, titles) are replaced;
    /// documents and multi-line boxes get the text inserted at the cursor, never wiped.
    static func type(_ text: String, into element: UIElement?) async -> TypeResult {
        let point = element?.center
        let frontWindow = NSWorkspace.shared.frontmostApplication.flatMap { app in
            ScreenReader.element(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedWindow")
        }
        if let title = point.flatMap(windowTitle(at:)) ?? frontWindow.map({ ScreenReader.string($0, "AXTitle") }),
           Redact.isSecretWindow(title) {
            log("  refusing to type into secret window \"\(title)\"")
            return .refused
        }
        if let element {
            mouseClick(at: element.center)
            if let ax = element.ax { AXUIElementSetAttributeValue(ax, "AXFocused" as CFString, kCFBooleanTrue) }
            try? await Task.sleep(for: .seconds(0.25))
        }
        let singleLine = ["AXTextField", "AXSearchField", "AXComboBox"].contains(element?.role ?? "")
        if singleLine { key(kVK_ANSI_A, flags: .maskCommand) }  // replace a query/title, never a document
        await paste(text, into: element?.ax)

        guard let ax = element?.ax else { return .notVerified }  // can't read back text Hand only saw in pixels
        if ScreenReader.string(ax, "AXValue").localizedCaseInsensitiveContains(text) { return .landed }
        // Paste didn't take. Only single-line fields may be overwritten directly.
        if singleLine {
            AXUIElementSetAttributeValue(ax, "AXValue" as CFString, text as CFString)
            try? await Task.sleep(for: .seconds(0.15))
            if ScreenReader.string(ax, "AXValue").localizedCaseInsensitiveContains(text) { return .landed }
        }
        typeString(text)
        try? await Task.sleep(for: .seconds(0.2))
        return ScreenReader.string(ax, "AXValue").localizedCaseInsensitiveContains(text) ? .landed : .failed
    }

    /// Pastes through the clipboard (web views accept this reliably), then restores the clipboard.
    /// The app handles ⌘V whenever it gets to it, so the old clipboard only comes back once the
    /// text has visibly landed (or after a long wait). Restoring too early once pasted the user's
    /// previous clipboard (an API key) into a document instead of Hand's text.
    static func paste(_ text: String, into ax: AXUIElement? = nil) async {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        key(kVK_ANSI_V, flags: .maskCommand)
        let probe = String(text.prefix(40))
        for _ in 0..<20 {  // up to 2s
            try? await Task.sleep(for: .seconds(0.1))
            if let ax, ScreenReader.string(ax, "AXValue").contains(probe) { break }
        }
        try? await Task.sleep(for: .seconds(0.2))  // let the paste finish past the first characters
        board.clearContents()
        let restored = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }

    /// Copies the front app's selection with ⌘C and returns it, restoring the clipboard.
    /// For apps (web pages, PDFs) that don't report their selection to Accessibility.
    static func copySelection() async -> String {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let before = board.changeCount
        key(kVK_ANSI_C, flags: .maskCommand)
        for _ in 0..<10 where board.changeCount == before { try? await Task.sleep(for: .seconds(0.05)) }
        let copied = board.changeCount == before ? "" : (board.string(forType: .string) ?? "")
        board.clearContents()
        let restored = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
        return copied
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
