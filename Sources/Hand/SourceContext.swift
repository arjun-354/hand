import AppKit
import ApplicationServices

/// What you were looking at when you pressed the talk key, so commands can say
/// "this" ("save this link to Notion", "send this to Ritesh") even after Hand
/// switches to another app.
struct SourceContext {
    var appName = ""
    var windowTitle = ""
    var link = ""
    var selectedText = ""
    var clipboard = ""

    /// Values Jev may choose to type, with a description of each.
    var typeableValues: [String: String] {
        var out: [String: String] = [:]
        if !link.isEmpty { out[link] = "The link (URL) of what was on screen in \(appName): \(windowTitle)" }
        if !windowTitle.isEmpty { out[windowTitle] = "The title of what was on screen in \(appName)" }
        if !selectedText.isEmpty { out[String(selectedText.prefix(500))] = "The text that was selected in \(appName)" }
        if !clipboard.isEmpty, clipboard != link { out[String(clipboard.prefix(500))] = "What was on the clipboard" }
        return out
    }

    /// Short description for Jev's state.
    var summary: [String: String] {
        ["app": appName, "title": windowTitle, "link": link,
         "selected_text": String(selectedText.prefix(200))].filter { !$0.value.isEmpty }
    }

    @MainActor
    static func capture(from app: NSRunningApplication) -> SourceContext {
        var ctx = SourceContext(appName: app.localizedName ?? "")
        ctx.clipboard = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        if let focused = ScreenReader.element(root, "AXFocusedUIElement") {
            ctx.selectedText = ScreenReader.string(focused, "AXSelectedText")
        }
        guard let window = ScreenReader.element(root, "AXFocusedWindow") ?? ScreenReader.element(root, "AXMainWindow")
        else { return ctx }
        ctx.windowTitle = ScreenReader.string(window, "AXTitle")
        ctx.link = findLink(in: window)
        return ctx
    }

    /// Browsers expose the page URL on their web area; document apps on the window.
    @MainActor
    private static func findLink(in window: AXUIElement) -> String {
        if let doc = urlString(ScreenReader.attr(window, "AXDocument")) { return doc }
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int) -> String? {
            guard depth < 25, visited < 1500 else { return nil }
            visited += 1
            if ScreenReader.string(e, "AXRole") == "AXWebArea", let url = urlString(ScreenReader.attr(e, "AXURL")) {
                return url
            }
            for child in (ScreenReader.attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
                if let found = walk(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk(window, depth: 0) ?? ""
    }

    private static func urlString(_ value: AnyObject?) -> String? {
        if let url = value as? URL { return url.isFileURL ? nil : url.absoluteString }
        if let string = value as? String, string.hasPrefix("http") { return string }
        return nil
    }
}
