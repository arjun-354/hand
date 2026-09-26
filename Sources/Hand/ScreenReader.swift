import AppKit
import ApplicationServices

/// One thing on screen Hand can act on.
struct UIElement {
    let id: String
    let role: String
    let label: String
    /// Global screen coordinates, top-left origin (same space as CGEvent).
    let frame: CGRect
    /// nil for text Hand saw in a screenshot rather than read through Accessibility.
    let ax: AXUIElement?
    let canPress: Bool

    var isTextInput: Bool { ["AXTextField", "AXSearchField", "AXTextArea", "AXComboBox"].contains(role) }
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Compact line Jev reads, e.g. "search field: Search".
    var summary: String { "\(Self.friendly(role)): \(label)" }

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
    static let maxElements = 180
    static let maxTotal = 250
    private static var enhanced: Set<pid_t> = []

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
        "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox", "AXRow", "AXOutlineRow",
        "AXCell", "AXTab", "AXDisclosureTriangle", "AXSlider",
    ]

    /// Everything Hand can see in `app`: its accessibility tree merged with the
    /// text in a screenshot of its windows (read in parallel).
    static func snapshot(of app: NSRunningApplication) async -> ScreenSnapshot {
        async let seen = ScreenVision.readText(pid: app.processIdentifier)
        let (title, axElements) = await accessibilityElements(of: app)
        let merged = merge(axElements, with: await seen)
        return ScreenSnapshot(appName: app.localizedName ?? "", windowTitle: title, elements: merged)
    }

    private static func accessibilityElements(of app: NSRunningApplication) async -> (String, [UIElement]) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)

        // Chromium/Electron apps (Spotify, Slack, Chrome, VS Code…) only build their
        // accessibility tree once asked. Give them a moment the first time.
        if !enhanced.contains(app.processIdentifier) {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            enhanced.insert(app.processIdentifier)
            try? await Task.sleep(for: .seconds(0.8))
        }

        let window = element(root, "AXFocusedWindow")
            ?? element(root, "AXMainWindow")
            ?? ((attr(root, "AXWindows") as? [AXUIElement])?.first)
        guard let window else { return ("", []) }

        let bounds = frame(of: window) ?? .infinite
        var out: [UIElement] = []
        var seen = Set<String>()
        var visited = 0

        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 60, visited < 6000, out.count < maxElements else { return }
            visited += 1
            let role = string(e, "AXRole")
            let actions = actionNames(e)
            let canPress = actions.contains("AXPress")

            if interactiveRoles.contains(role) || canPress,
               let f = frame(of: e), f.width > 2, f.height > 2, f.intersects(bounds) {
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
        walk(window, depth: 0)
        return (string(window, "AXTitle"), pruneDuplicates(out))
    }

    /// Adds screenshot text that Accessibility didn't already cover, then numbers everything.
    private static func merge(_ ax: [UIElement], with text: [ScreenVision.TextBox]) -> [UIElement] {
        var all = ax
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
            UIElement(id: "e\(i)", role: e.role, label: e.label, frame: e.frame, ax: e.ax, canPress: e.canPress)
        }
    }

    /// Web apps nest a row, its text and its button at the same spot. Keep the
    /// most descriptive one and renumber so ids stay compact.
    private static func pruneDuplicates(_ elements: [UIElement]) -> [UIElement] {
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

    private static func label(for e: AXUIElement, role: String) -> String {
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

    private static func descendantTexts(_ e: AXUIElement, limit: Int, depth: Int = 0) -> [String] {
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
