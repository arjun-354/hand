import AppKit

/// Carries out a Command on the Mac and returns what to show in the notch.
@MainActor
enum Actions {
    static func run(_ command: Command) async -> Phase {
        switch command {
        case .open(let app):
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: config)
                return .done("Opened \(app.name)")
            } catch {
                return .failed("Couldn't open \(app.name)")
            }

        case .quit(let app):
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
            }
            guard !running.isEmpty else { return .done("\(app.name) isn't open") }
            running.forEach { $0.terminate() }
            return .done("Quit \(app.name)")

        case .unsure(let message):
            return .failed(message)
        }
    }
}
