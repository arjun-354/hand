import Foundation
import Observation

enum Phase: Equatable {
    case idle
    case listening
    case thinking
    case done(String)
    case failed(String)
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
    @ObservationIgnored private var apps = AppCatalog.scan()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var permissionsOK = false

    init() {
        speech.onPartial = { [weak self] in self?.transcript = $0 }
        speech.onLevel = { [weak self] in self?.level = $0 }
        log("\(apps.count) apps, jev \(JevClient.fromConfig() == nil ? "not configured (using local matcher)" : "configured")")
    }

    func startListening() {
        task?.cancel()
        transcript = ""
        level = 0
        phase = .listening
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

            // Rescan apps and reread the key each time, so installs and key changes apply without a restart.
            apps = AppCatalog.scan()
            let brain = Brain(jev: JevClient.fromConfig(), apps: apps)
            do {
                let command = try await brain.decide(text)
                finish(await Actions.run(command))
            } catch {
                log("brain error: \(error)")
                finish(.failed("\(error)"))
            }
        }
    }

    func finish(_ result: Phase) {
        phase = result
        task = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            phase = .idle
        }
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
