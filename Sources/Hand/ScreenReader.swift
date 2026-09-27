import AppKit
import ApplicationServices

/// One thing on screen Hand can act on.
struct UIElement: @unchecked Sendable {  // AXUIElement refs are safe to pass between threads
    let id: String
    let role: String
    let label: String
    /// Global screen coordinates, top-left origin (same space as CGEvent).
    let frame: CGRect
    /// nil for text Hand saw in a screenshot rather than read through Accessibility.
    let ax: AXUIElement?
    let canPress: Bool
    /// Which section it sits in, e.g. `in "Scripting", under "Production Board"`.
    var context = ""

    var isTextInput: Bool { ["AXTextField", "AXSearchField", "AXTextArea", "AXComboBox"].contains(role) }
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Compact line Jev reads, e.g. "search field: Search".
    var summary: String {
        let base = "\(Self.friendly(role)): \(label)"
        return context.isEmpty ? base : "\(base) (\(context))"
    }

    static func friendly(_ role: String) -> String {
        switch role {
        case "AXButton": "button"
        case "AXRow", "AXCell", "AXOutlineRow": "list item"
        case "AXLink": "link"
        case "AXTextField", "AXTextArea", "AXComboBox": "text field"
        case "AXSearchField": "search field"
        case "AXCheckBox": "checkbox"
        case "AXRadioButton", "AXTab": "tab"
        case "AXPopUpButton", "AXMenuButton": "menu"
        case "AXSlider": "slider"
        case "AXStaticText": "text"
        case "AXImage": "image"
        case visibleTextRole: "on screen"
        default: role.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }
}

/// Role for text found by ScreenVision in a screenshot.
let visibleTextRole = "HandVisibleText"

struct ScreenSnapshot {
    let appName: String
    let windowTitle: String
    let elements: [UIElement]

    func element(_ id: String) -> UIElement? { elements.first { $0.id == id } }
}

/// Reads the front window of an app through the Accessibility API and flattens
/// it into a list of labelled, actionable elements.
@MainActor
enum ScreenReader {
    /// Jev accepts up to 255 options per choice; leave room for vision results.
    nonisolated static let maxElements = 180
    nonisolated static let maxTotal = 250
    private static var enhanced: Set<pid_t> = []

    nonisolated private static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
        "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox", "AXRow", "AXOutlineRow",
        "AXCell", "AXTab", "AXDisclosureTriangle", "AXSlider",
    ]

    /// Everything Hand can see in `app`: its accessibility tree merged with the
    /// text in a screenshot of its windows (read in parallel).
    static func snapshot(of app: NSRunningApplication) async -> ScreenSnapshot {
        let started = Date()
        let pid = app.processIdentifier
        async let seen = ScreenVision.readText(pid: pid)

        // Chromium/Electron apps (Spotify, Slack, Chrome, VS Code…) only build their
        // accessibility tree once asked. Give them a moment the first time.
        if !enhanced.contains(pid) {
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            enhanced.insert(pid)
            try? await Task.sleep(for: .seconds(0.8))
        }

        // Walking the tree is thousands of cross-process calls; off the main thread
        // so the notch and speech recognition never freeze.
        let (title, axElements) = await Task.detached(priority: .userInitiated) {
            accessibilityElements(pid: pid)
        }.value
        let axTime = Date().timeIntervalSince(started)
        let text = await seen
        let merged = merge(axElements, with: text)
        log(String(format: "screen read: %d accessibility + %d text in %.1fs (tree %.1fs)",
                   axElements.count, text.count, Date().timeIntervalSince(started), axTime))
        return ScreenSnapshot(appName: app.localizedName ?? "", windowTitle: title, elements: merged)
    }

    /// Time budget for one tree walk; slow apps get a partial but usable list.
    nonisolated static let walkBudget: TimeInterval = 1.5

    nonisolated private static func accessibilityElements(pid: pid_t) -> (String, [UIElement]) {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let deadline = Date().addingTimeInterval(walkBudget)

        let focused = element(root, "AXFocusedWindow") ?? element(root, "AXMainWindow")
        // Some apps split one window into several (full-screen Chrome: tab strip,
        // toolbar and page are separate windows), so read every visible one.
        var windows = (attr(root, "AXWindows") as? [AXUIElement]) ?? []
        windows = windows.filter { ScreenReader.frame(of: $0).map { $0.width > 40 && $0.height > 20 } ?? false
            && (attr($0, "AXMinimized") as? Bool) != true }
        if let focused { windows.removeAll { CFEqual($0, focused) }; windows.insert(focused, at: 0) }
        guard let window = windows.first else { return ("", []) }
        let screenBounds = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        var out: [UIElement] = []
        var headings: [(label: String, frame: CGRect)] = []
        var seen = Set<String>()
        var visited = 0
        var bounds = CGRect.infinite  // the window currently being walked

        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 60, visited < 4000, out.count < maxElements, Date() < deadline else { return }
            visited += 1
            let role = string(e, "AXRole")
            let actions = actionNames(e)
            let canPress = actions.contains("AXPress")

            if role == "AXHeading", let f = frame(of: e), f.intersects(bounds) {
                let text = self.label(for: e, role: role)
                if !text.isEmpty { headings.append((String(text.prefix(60)), f)) }
            }

            if interactiveRoles.contains(role) || canPress,
               let f = frame(of: e), f.width > 2, f.height > 2, f.intersects(bounds), f.intersects(screenBounds) {
                let label = self.label(for: e, role: role)
                if !label.isEmpty {
                    let key = "\(label)|\(Int(f.midX / 8))|\(Int(f.midY / 8))"
                    if seen.insert(key).inserted {
                        out.append(UIElement(id: "e\(out.count)", role: role, label: label,
                                             frame: f, ax: e, canPress: canPress))
                    }
                }
            }
            for child in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        for w in windows.prefix(4) where Date() < deadline {
            bounds = frame(of: w) ?? .infinite
            walk(w, depth: 0)
        }
        return (string(window, "AXTitle"), addContext(to: pruneDuplicates(out), headings: headings))
    }

    /// Adds screenshot text that Accessibility didn't already cover, then numbers everything.
    nonisolated private static func merge(_ ax: [UIElement], with text: [ScreenVision.TextBox]) -> [UIElement] {
        // Qt apps label buttons with code names ("ExportOkBtn"); prefer the words drawn on them.
        var all = ax.map { e -> UIElement in
            guard looksLikeIdentifier(e.label),
                  let shown = text.first(where: { e.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
            else { return e }
            return UIElement(id: e.id, role: e.role, label: "\(shown.text) (\(e.label))", frame: e.frame, ax: e.ax, canPress: e.canPress, context: e.context)
        }
        for box in text where all.count < maxTotal {
            let center = CGPoint(x: box.frame.midX, y: box.frame.midY)
            let covered = ax.contains { e in
                e.frame.insetBy(dx: -4, dy: -4).contains(center)
                    && (e.label.localizedCaseInsensitiveContains(box.text) || box.text.localizedCaseInsensitiveContains(e.label))
            }
            if !covered {
                all.append(UIElement(id: "", role: visibleTextRole, label: box.text,
                                     frame: box.frame, ax: nil, canPress: false))
            }
        }
        return all.enumerated().map { i, e in
            UIElement(id: "e\(i)", role: e.role, label: e.label, frame: e.frame, ax: e.ax, canPress: e.canPress, context: e.context)
        }
    }

    /// Web apps nest a row, its text and its button at the same spot. Keep the
    /// most descriptive one and renumber so ids stay compact.
    nonisolated private static func pruneDuplicates(_ elements: [UIElement]) -> [UIElement] {
        let kept = elements.filter { e in
            if e.label == "•" { return false }
            return !elements.contains { other in
                other.id != e.id
                    && abs(other.center.x - e.center.x) < 6 && abs(other.center.y - e.center.y) < 6
                    && other.label.count > e.label.count
                    && other.label.localizedCaseInsensitiveContains(e.label.components(separatedBy: " — ").first ?? e.label)
                    && !e.isTextInput
            }
        }
        return kept
    }

    /// Boards and lists repeat the same controls ("New page" in every column).
    /// Label each element with the column header directly above it and the
    /// nearest page heading above it, so Jev can tell them apart.
    nonisolated private static func addContext(to elements: [UIElement], headings: [(label: String, frame: CGRect)]) -> [UIElement] {
        let headerRoles: Set<String> = ["AXMenuButton", "AXPopUpButton", "AXTab", "AXRadioButton"]
        let headers = elements.filter { headerRoles.contains($0.role) && $0.label.count <= 40 }
            .map { (label: $0.label, frame: $0.frame) } + headings

        return elements.map { e in
            // Column header: above this element, horizontally inside its span.
            let column = headers
                .filter { $0.frame.maxY <= e.frame.minY + 2 && $0.label != e.label
                    && $0.frame.midX >= e.frame.minX - 12 && $0.frame.minX <= e.frame.maxX
                    && e.frame.minY - $0.frame.maxY < 700 }
                .min { e.frame.minY - $0.frame.maxY < e.frame.minY - $1.frame.maxY }
            // Section heading: nearest heading above that shares some horizontal space
            // (so a sidebar isn't labelled with the main pane's headings).
            let section = headings
                .filter { $0.frame.maxY <= e.frame.minY + 2 && $0.label != e.label && $0.label != column?.label
                    && $0.frame.minX < e.frame.maxX && $0.frame.maxX > e.frame.minX }
                .min { e.frame.minY - $0.frame.maxY < e.frame.minY - $1.frame.maxY }

            var parts: [String] = []
            if let column { parts.append("in \"\(column.label)\"") }
            if let section { parts.append("under \"\(section.label)\"") }
            var copy = e
            copy.context = parts.joined(separator: ", ")
            return copy
        }
    }

    /// "ExportOkBtn", "automationcancel", "save_button": no spaces, reads like code.
    nonisolated private static func looksLikeIdentifier(_ label: String) -> Bool {
        guard label.count > 3, label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return false }
        let hasInnerCapital = label.dropFirst().contains(where: \.isUppercase)
        return hasInnerCapital || label.contains("_") || label == label.lowercased()
    }

    // MARK: - AX helpers

    nonisolated static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attr(e, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func string(_ e: AXUIElement, _ name: String) -> String {
        (attr(e, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func actionNames(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return (names as? [String]) ?? []
    }

    nonisolated static func frame(of e: AXUIElement) -> CGRect? {
        guard let posValue = attr(e, "AXPosition"), let sizeValue = attr(e, "AXSize") else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    nonisolated private static func label(for e: AXUIElement, role: String) -> String {
        var parts = [string(e, "AXTitle"), string(e, "AXDescription")]
        if ["AXTextField", "AXSearchField", "AXTextArea", "AXComboBox"].contains(role) {
            parts.append(string(e, "AXPlaceholderValue"))
            let value = string(e, "AXValue")
            if !value.isEmpty { parts.append("contains \"\(value.prefix(40))\"") }
        } else if role == "AXCheckBox" || role == "AXRadioButton" {
            if let on = attr(e, "AXValue") as? Int { parts.append(on == 1 ? "(on)" : "(off)") }
        }
        parts.append(string(e, "AXHelp"))
        var label = parts.filter { !$0.isEmpty }.reduce(into: [String]()) { acc, p in
            if !acc.contains(p) { acc.append(p) }
        }.joined(separator: " — ")

        // Rows, cells and unlabeled buttons usually carry their text in children.
        if label.isEmpty || role == "AXRow" || role == "AXCell" || role == "AXOutlineRow" {
            let texts = descendantTexts(e, limit: 3)
            if !texts.isEmpty { label = ([label] + texts).filter { !$0.isEmpty }.joined(separator: " — ") }
        }
        return String(label.prefix(120))
    }

    nonisolated private static func descendantTexts(_ e: AXUIElement, limit: Int, depth: Int = 0) -> [String] {
        guard depth < 5 else { return [] }
        var out: [String] = []
        for child in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
            if string(child, "AXRole") == "AXStaticText" {
                let v = string(child, "AXValue").isEmpty ? string(child, "AXTitle") : string(child, "AXValue")
                if !v.isEmpty { out.append(v) }
            } else {
                out += descendantTexts(child, limit: limit - out.count, depth: depth + 1)
            }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }
}
