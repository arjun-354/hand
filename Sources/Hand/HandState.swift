import AppKit
import Observation

enum Phase: Equatable {
    case idle
    case listening
    case thinking
    case working(String)
    case done(String)
    case failed(String)
    /// A readable answer that stays open until dismissed.
    case answer(String)
}

@MainActor
@Observable
final class HandState {
    var phase: Phase = .idle
    /// Live transcript while listening.
    var transcript: String = ""
    /// 0...1 microphone level, drives the waveform.
    var level: Double = 0

    @ObservationIgnored private let speech = SpeechListener()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var permissionsOK = false
    /// Screen read started the moment the talk key goes down, so it's ready when you stop talking.
    @ObservationIgnored private var prefetch: (pid: pid_t, snapshot: Task<ScreenSnapshot, Never>)?
    /// Link, title, selection and clipboard from the app in front at key-down.
    @ObservationIgnored private var source: Task<SourceContext, Never>?
    /// Screenshot of the front window at key-down; only sent anywhere if the request is about it.
    @ObservationIgnored private var windowImage: Task<Data?, Never>?

    init() {
        speech.onPartial = { [weak self] in self?.transcript = $0 }
        speech.onLevel = { [weak self] in self?.level = $0 }
        speech.vocabulary = ["4K", "1080p", "720p", "1440p", "60fps", "30fps", "24fps", "HEVC", "H.264", "MP4",
                             "export", "Weeknd", "System Settings"] + AppCatalog.scan().map(\.name)
        log("started: \(AppCatalog.scan().count) apps, jev \(JevClient.fromConfig() == nil ? "NOT configured" : "configured"), brain \(Brain.fromConfig()?.provider.rawValue ?? "off"), accessibility \(AXIsProcessTrusted()), screen recording \(ScreenVision.hasPermission)")
    }

    /// Pressing the talk key also cancels whatever Hand was doing.
    func startListening() {
        task?.cancel()
        transcript = ""
        level = 0
        phase = .listening
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            prefetch = (front.processIdentifier, Task { await ScreenReader.snapshot(of: front) })
            let pid = front.processIdentifier, name = front.localizedName ?? ""
            source = Task.detached { SourceContext.capture(pid: pid, appName: name) }
            windowImage = Task.detached { await ScreenVision.windowImageJPEG(pid: pid) }
        }
        task = Task {
            if !permissionsOK {
                if let failure = await SpeechListener.requestPermissions() {
                    finish(.failed(failure.description)); return
                }
                permissionsOK = true
            }
            guard phase == .listening else { return }  // key already released
            do { try speech.start() } catch { finish(.failed("Mic error: \(error)")) }
        }
    }

    func stopListening() {
        guard phase == .listening else { return }
        phase = .thinking
        level = 0
        task = Task {
            let text = await speech.stop()
            transcript = text
            log("heard: \(text)")
            guard !text.isEmpty else { finish(.failed("Didn't hear anything")); return }
            await run(text)
        }
    }

    /// Runs a command as if it had been spoken. Used by voice and by `--say`.
    func run(_ text: String) async {
        guard let jev = JevClient.fromConfig() else {
            finish(.failed("Add your TypeSafe key to ~/.config/hand/.env")); return
        }
        phase = .thinking
        transcript = text
        let seen = prefetch
        prefetch = nil
        var looking = await source?.value ?? SourceContext()
        source = nil
        var image = windowImage
        windowImage = nil
        if image == nil, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            let pid = front.processIdentifier
            image = Task.detached { await ScreenVision.windowImageJPEG(pid: pid) }  // --say runs have no key-down
        }
        if looking.appName.isEmpty, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            let pid = front.processIdentifier, name = front.localizedName ?? ""
            looking = await Task.detached { SourceContext.capture(pid: pid, appName: name) }.value  // --say runs have no key-down
        }
        log("looking at: \(looking.appName) \"\(looking.windowTitle)\" link=\(looking.link.isEmpty ? "-" : looking.link)")
        let agent = Agent(jev: jev, apps: AppCatalog.scan(), prefetched: seen, source: looking, image: image) { [weak self] step in
            guard !Task.isCancelled else { return }  // a new talk press took over
            self?.phase = .working(step)
        }
        do {
            let result = try await agent.run(text)
            log("result: \(result)")
            guard !Task.isCancelled else { return }
            finish(result)
        } catch is CancellationError {
            // A new talk press took over; it owns the notch now.
        } catch let error as URLError where error.code == .cancelled {
            // Same, but the cancel landed during a Jev request.
        } catch {
            log("agent error: \(error)")
            finish(.failed("\(error)"))
        }
    }

    func finish(_ result: Phase) {
        phase = result
        if case .answer = result { return }  // stays until the user closes it
        task = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            phase = .idle
        }
    }

    /// Closes an answer panel (close button, Esc, or the next talk press).
    func dismiss() {
        task?.cancel()
        phase = .idle
    }

    /// Animation-only walkthrough; doesn't touch the mic or run anything.
    func playDemo() {
        task?.cancel()
        task = Task {
            phase = .listening
            for words in ["open", "open Spotify"] {
                try? await Task.sleep(for: .seconds(0.7))
                transcript = words
            }
            try? await Task.sleep(for: .seconds(0.8))
            phase = .thinking
            try? await Task.sleep(for: .seconds(1.0))
            finish(.done("Opened Spotify"))
        }
    }
}
