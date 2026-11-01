import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var isSending = false
    @Published private(set) var status: String?

    let store: ChatHistoryStore
    let speech: SpeechService
    private var task: Task<Void, Never>?
    private var timedOut = false
    private var requestID = UUID()

    init(store: ChatHistoryStore) {
        self.store = store
        self.speech = SpeechService()
    }

    var canStop: Bool { isSending || speech.isSpeaking }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let convID = store.selectedID else { return }
        speech.stop()
        input = ""
        store.append(ChatMessage(role: .user, content: text), to: convID)

        let provider: ChatProvider
        do {
            provider = try ChatProvider.fromSettings()
        } catch {
            store.append(ChatMessage(role: .assistant, content: error.localizedDescription, isError: true), to: convID)
            SoundManager.shared.playError()
            return
        }

        var history: [[String: String]] = [["role": "system", "content": AppSettings.systemPrompt]]
        for m in store.messages(in: convID) where !m.isError && !m.content.isEmpty {
            history.append(["role": m.role.rawValue, "content": m.content])
        }

        let reply = ChatMessage(role: .assistant, content: "")
        store.append(reply, to: convID)

        isSending = true
        timedOut = false
        status = "Thinking"
        SoundManager.shared.startLoop()

        let request = UUID()
        requestID = request
        task = Task { [weak self] in
            await self?.run(provider: provider, history: history, replyID: reply.id, convID: convID)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self, self.requestID == request, self.isSending,
                  self.status != "Preparing voice" else { return }
            self.timedOut = true
            self.task?.cancel()
        }
    }

    func stop() {
        if isSending { task?.cancel() }
        speech.stop()
    }

    private func run(provider: ChatProvider, history: [[String: String]], replyID: UUID, convID: UUID) async {
        var text = ""
        var lastFlush = Date()
        do {
            for try await piece in provider.stream(history) {
                if status != nil { status = nil }
                text += piece
                store.setContent(text, message: replyID, in: convID, persist: false)
                if Date().timeIntervalSince(lastFlush) > 2 { store.save(); lastFlush = Date() }
            }
            try Task.checkCancellation()
        } catch {
            SoundManager.shared.stopLoop()
            SoundManager.shared.playError()
            let note: String
            if timedOut {
                note = "**Request stopped:** it could not finish within 45 seconds."
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                note = "Request cancelled."
            } else {
                note = "**Request failed:** \(error.localizedDescription)"
            }
            let content = text.isEmpty ? note : text + "\n\n" + note
            store.setContent(content, isError: text.isEmpty, message: replyID, in: convID, persist: true)
            finish()
            return
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = "I completed the request, but the model returned no text response."
        }
        store.setContent(text, message: replyID, in: convID, persist: true)

        guard AppSettings.speechEnabled else {
            SoundManager.shared.stopLoop()
            SoundManager.shared.playSuccess()
            finish()
            return
        }

        if AppSettings.speechProvider == .fish, let key = Keychain.get(AppSettings.fishKeyName) {
            // keep the loop going until the full answer audio is ready
            status = "Preparing voice"
            do {
                let audio = try await speech.fishAudio(text, key: key, voiceID: AppSettings.fishVoiceID)
                try Task.checkCancellation()
                SoundManager.shared.stopLoop()
                SoundManager.shared.playSuccess()
                finish()
                try? await Task.sleep(nanoseconds: 700_000_000)
                speech.play(audio)
            } catch {
                SoundManager.shared.stopLoop()
                SoundManager.shared.playError()
                finish()
            }
        } else {
            SoundManager.shared.stopLoop()
            SoundManager.shared.playSuccess()
            finish()
            try? await Task.sleep(nanoseconds: 600_000_000)
            speech.speakSystem(text)
        }
    }

    private func finish() {
        isSending = false
        status = nil
        task = nil
    }
}
