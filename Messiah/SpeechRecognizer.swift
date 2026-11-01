import Foundation
import Speech
import AVFoundation

/// Apple's built-in speech-to-text (SFSpeechRecognizer) on the microphone.
/// Publishes the live transcript and a 0...1 mic level for animations, and
/// stops by itself after a short pause in speech.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var isListening = false

    /// Seconds of silence (after some words) that count as "done talking".
    var silenceTimeout: Double = 1.4
    /// Called whenever a listening session ends (text is nil if nothing was said).
    var onFinish: ((String?) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var continuation: CheckedContinuation<String?, Never>?

    static func requestPermission() async -> Bool {
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    /// Listens until the user pauses, then returns what they said.
    func listenOnce() async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            continuation = c
            do { try start() } catch { finish(nil) }
        }
    }

    func start() throws {
        stopEngine()
        transcript = ""
        guard let recognizer, recognizer.isAvailable else {
            throw ProviderError(message: "Speech recognition isn't available right now.")
        }
        AudioSessionMode.record()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(req, owner: self))
        engine.prepare()
        try engine.start()
        isListening = true
        task = recognizer.recognitionTask(with: req, resultHandler: Self.makeHandler(owner: self))
    }

    /// Stop now and deliver what was heard.
    func finish(_ text: String?) {
        let wasActive = isListening || continuation != nil
        stopEngine()
        let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = (cleaned?.isEmpty ?? true) ? nil : cleaned
        let c = continuation
        continuation = nil
        c?.resume(returning: result)
        if wasActive { onFinish?(result) }
    }

    func cancel() { finish(nil) }

    // MARK: - internals

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty {
            transcript = text
            armSilenceTimer()
        }
        if isFinal || failed { finish(transcript) }
    }

    private func armSilenceTimer() {
        silenceTimer?.cancel()
        let wait = silenceTimeout
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isListening else { return }
            self.finish(self.transcript)
        }
    }

    private func stopEngine() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isListening = false
        level = 0
    }

    private func setLevel(_ v: CGFloat) {
        guard isListening else { return }
        level = level * 0.6 + v * 0.4   // smooth
    }

    // Built outside the main actor: these run on audio / recognizer threads.
    nonisolated private static func makeTap(_ req: SFSpeechAudioBufferRecognitionRequest,
                                            owner: SpeechRecognizer) -> AVAudioNodeTapBlock {
        return { [weak owner] buffer, _ in
            req.append(buffer)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            let db = 20 * log10(max(rms, 0.000_001))
            let v = CGFloat(min(max((db + 50) / 40, 0), 1))
            Task { @MainActor in owner?.setLevel(v) }
        }
    }

    nonisolated private static func makeHandler(owner: SpeechRecognizer) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in owner?.handle(text: text, isFinal: isFinal, failed: failed) }
        }
    }
}
