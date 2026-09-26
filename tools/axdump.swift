// Dumps the actionable UI elements of an app's front window: swift tools/axdump.swift <bundle-id>
import AppKit
import ApplicationServices

print("trusted:", AXIsProcessTrusted())
let bid = CommandLine.arguments.dropFirst().first ?? "com.apple.systempreferences"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { print("not running"); exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 0.5)

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
var count = 0
func walk(_ e: AXUIElement, _ depth: Int) {
    guard depth < 40, count < 400 else { return }
    let role = str(e, "AXRole")
    let label = [str(e, "AXTitle"), str(e, "AXDescription"), str(e, "AXValue"), str(e, "AXHelp")].filter { !$0.isEmpty }.joined(separator: " | ")
    var actions: CFArray?
    AXUIElementCopyActionNames(e, &actions)
    let acts = (actions as? [String]) ?? []
    if !label.isEmpty && (acts.contains("AXPress") || ["AXRow","AXTextField","AXButton","AXLink","AXCell","AXStaticText","AXSearchField"].contains(role)) {
        count += 1
        print(String(repeating: " ", count: min(depth, 20)), role, "—", label.prefix(80), acts.contains("AXPress") ? "[press]" : "")
    }
    for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
}
let windows = (attr(root, "AXWindows") as? [AXUIElement]) ?? []
print("windows:", windows.count)
if let w = windows.first { walk(w, 0) }
print("elements:", count)
