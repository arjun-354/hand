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
    /// Live transcript while listening. Filled by speech-to-text later.
    var transcript: String = ""
    /// 0...1 microphone level, drives the waveform. Faked until audio is wired up.
    var level: Double = 0

    private var task: Task<Void, Never>?

    func startListening() {
        task?.cancel()
        transcript = ""
        phase = .listening
    }

    func stopListening() {
        guard phase == .listening else { return }
        phase = .thinking
        // Placeholder pipeline: speech-to-text -> Jev decision -> action goes here.
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            self?.finish(.done("Opening Spotify"))
        }
    }

    func finish(_ result: Phase) {
        task?.cancel()
        phase = result
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.phase = .idle
        }
    }
}
