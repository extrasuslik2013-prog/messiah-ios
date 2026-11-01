import Foundation

/// Hands-free voice conversation: listen → send → speak the answer → listen again.
@MainActor
final class LiveSession: ObservableObject {
    enum Phase { case idle, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var problem: String?

    let recognizer = SpeechRecognizer()
    let vm: ChatViewModel
    private var loop: Task<Void, Never>?

    init(vm: ChatViewModel) {
        self.vm = vm
        recognizer.silenceTimeout = 1.3
    }

    func start() {
        guard loop == nil else { return }
        problem = nil
        vm.speech.stop()
        loop = Task { [weak self] in
            guard await SpeechRecognizer.requestPermission() else {
                self?.problem = "Allow Microphone and Speech Recognition for Messiah in the iPhone Settings app to use live chat."
                self?.phase = .idle
                return
            }
            guard let self else { return }
            while !Task.isCancelled {
                self.phase = .listening
                guard let text = await self.recognizer.listenOnce() else {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                if Task.isCancelled { break }

                self.phase = .thinking
                await self.vm.sendAndWait(text, speak: true)
                if Task.isCancelled { break }

                if self.vm.speech.isSpeaking { self.phase = .speaking }
                while self.vm.speech.isSpeaking && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        recognizer.cancel()
        vm.stop()
        phase = .idle
        AudioSessionMode.playback()
    }

    /// Tap on the orb: send now while listening, cut in while speaking,
    /// or cancel while thinking.
    func interrupt() {
        switch phase {
        case .listening: recognizer.finish(recognizer.transcript)
        case .speaking: vm.speech.stop()
        case .thinking: vm.stop()
        case .idle: break
        }
    }
}
