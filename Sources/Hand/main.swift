import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Accessory: no Dock icon, no app switcher entry. Hand lives in the notch.
    app.setActivationPolicy(.accessory)
    app.run()
}
