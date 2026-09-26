import AVFoundation
import Speech

/// Push-to-talk speech-to-text using Apple's recognizer (on-device when available).
@MainActor
final class SpeechListener {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = false
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty {
                    self.latest = text
                    self.onPartial?(text)
                }
                if isFinal || error != nil { self.resolveFinal() }
            }
        }
    }

    /// Stops the mic and waits briefly for the recognizer's final transcript.
    func stop() async -> String {
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
