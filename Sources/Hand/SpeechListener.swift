import AVFoundation
import Speech

/// Push-to-talk speech-to-text using Apple's recognizer (on-device when available).
@MainActor
final class SpeechListener {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    /// Words the recognizer should expect: app names, UI terms like "4K".
    var vocabulary: [String] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    /// Text from earlier recognition passes in this recording.
    private var committed = ""
    private var passes = 0
    private var recording = false
    private let audioSink = AudioSink()
    private var finalContinuation: CheckedContinuation<String, Never>?

    enum Failure: Error, CustomStringConvertible {
        case notAuthorized(String)
        case unavailable
        var description: String {
            switch self {
            case .notAuthorized(let what): "Allow \(what) for Hand in System Settings"
            case .unavailable: "Speech recognition unavailable"
            }
        }
    }

    static func requestPermissions() async -> Failure? {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speech == .authorized else { return .notAuthorized("Speech Recognition") }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { return .notAuthorized("Microphone") }
        return nil
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        cancel()
        latest = ""
        committed = ""
        passes = 0
        recording = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sink = audioSink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            sink.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }
        engine.prepare()
        try engine.start()
        beginRecognition()
    }

    /// Starts a recognition pass. The recognizer can end a pass on its own after
    /// a pause; while the key is still held we keep what it heard and start another.
    private func beginRecognition() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = false
        request.contextualStrings = Array(vocabulary.prefix(100))
        self.request = request
        audioSink.request = request
        passes += 1

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let text, !text.isEmpty {
                    self.latest = [self.committed, text].filter { !$0.isEmpty }.joined(separator: " ")
                    self.onPartial?(self.latest)
                }
                guard isFinal || error != nil else { return }
                if self.recording && self.passes < 20 {
                    self.committed = self.latest
                    self.beginRecognition()
                } else {
                    self.resolveFinal()
                }
            }
        }
    }

    /// Stops the mic and waits briefly for the recognizer's final transcript.
    func stop() async -> String {
        recording = false
        guard request != nil else { return latest }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()

        let text = await withCheckedContinuation { cont in
            finalContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                self?.resolveFinal()
            }
        }
        task = nil
        request = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        recording = false
        audioSink.request = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        resolveFinal()
    }

    private func resolveFinal() {
        finalContinuation?.resume(returning: latest)
        finalContinuation = nil
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        // Map roughly -50dB...-10dB onto 0...1.
        let db = 20 * log10(max(rms, 1e-6))
        return Double(min(max((db + 50) / 40, 0), 1))
    }
}

/// Hands mic buffers from the audio thread to whichever recognition request is current.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer) { request?.append(buffer) }
}
