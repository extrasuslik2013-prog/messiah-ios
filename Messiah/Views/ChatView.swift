import SwiftUI

struct ChatView: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var store: ChatHistoryStore
    @ObservedObject private var speech: SpeechService
    @FocusState private var focused: Bool
    @StateObject private var dictation: SpeechRecognizer
    @StateObject private var live: LiveSession
    @State private var showLive = false
    @State private var micDenied = false
    @State private var dictationBase = ""
    @State private var dictationError: String?

    init(vm: ChatViewModel, store: ChatHistoryStore) {
        self._vm = ObservedObject(wrappedValue: vm)
        self._store = ObservedObject(wrappedValue: store)
        self._speech = ObservedObject(wrappedValue: vm.speech)
        self._dictation = StateObject(wrappedValue: SpeechRecognizer())
        self._live = StateObject(wrappedValue: LiveSession(vm: vm))
    }

    private var messages: [ChatMessage] { store.currentMessages }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if messages.isEmpty {
                    GeminiBackgroundGlow().opacity(0.55)
                    Text(HybridStore.shared.welcomeText)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    messageList
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { focused = false }
            .overlay(alignment: .top) {
                if let notice = vm.notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 6)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: vm.notice)

            inputBar
        }
        .fullScreenCover(isPresented: $showLive) {
            LiveChatView(session: live, store: store) { showLive = false }
        }
        .alert("Voice input unavailable", isPresented: Binding(
            get: { dictationError != nil }, set: { if !$0 { dictationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictationError ?? "")
        }
        .alert("Microphone access needed", isPresented: $micDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow Microphone and Speech Recognition for Messiah in the iPhone Settings app.")
        }
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.finish(dictation.transcript)
            return
        }
        guard !vm.isSending else { return }
        Task {
            guard await SpeechRecognizer.requestPermission() else { micDenied = true; return }
            let base = vm.input.isEmpty ? "" : vm.input + " "
            dictationBase = base
            let model = vm
            dictation.silenceTimeout = 2.5
            dictation.onFinish = { text in
                if let text { model.input = base + text }
                SoundManager.shared.micOff()
                AudioSessionMode.playback()
            }
            SoundManager.shared.micOn()
            try? await Task.sleep(nanoseconds: 250_000_000)
            do {
                try dictation.start()
            } catch {
                AudioSessionMode.playback()
                dictationError = error.localizedDescription
            }
        }
    }

    private func openLive() {
        focused = false
        if dictation.isListening { dictation.cancel() }
        vm.stop()
        showLive = true
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(messages) { m in
                        MessageRow(message: m, status: m.id == messages.last?.id ? vm.status : nil)
                            .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.selectedID) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: messages.last?.content) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(dictation.isListening ? "Listening…" : HybridStore.shared.inputPlaceholder, text: $vm.input, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.leading, 16)
                .padding(.vertical, 11)
                .onChange(of: dictation.transcript) { _, t in
                    if dictation.isListening, !t.isEmpty { vm.input = dictationBase + t }
                }

            Button(action: toggleDictation) {
                Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(dictation.isListening ? AnyShapeStyle(Palette.magenta) : AnyShapeStyle(.secondary))
                    .frame(width: 34, height: 34)
                    .scaleEffect(1 + dictation.level * 0.35)
                    .animation(.easeOut(duration: 0.1), value: dictation.level)
            }
            .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate")
            .padding(.bottom, 5)
            .disabled(vm.isSending)

            actionButton
                .padding(.trailing, 6)
                .padding(.bottom, 5)
        }
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(LinearGradient(colors: [Palette.magenta, Palette.coral, Palette.amber],
                                             startPoint: .leading, endPoint: .trailing),
                              lineWidth: dictation.isListening ? 1.5 : 0)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    private var hasText: Bool {
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var actionButton: some View {
        if vm.isSending || speech.isSpeaking {
            Button { vm.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary))
            }
            .accessibilityLabel("Stop")
        } else if hasText {
            Button {
                if dictation.isListening { dictation.cancel() }
                vm.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(LinearGradient(colors: [Palette.magenta, Palette.coral],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .accessibilityLabel("Send")
        } else {
            Button(action: openLive) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AngularGradient(colors: Palette.orb, center: .center)))
            }
            .accessibilityLabel("Live chat")
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let status: String?

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 50)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.content.isEmpty {
                    Text(Self.markdown(message.content))
                        .textSelection(.enabled)
                        .foregroundStyle(message.isError ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let status {
                    GeminiShimmerText(text: status)
                }
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
