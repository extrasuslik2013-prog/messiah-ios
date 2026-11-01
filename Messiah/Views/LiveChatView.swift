import SwiftUI

/// Full-screen voice mode: just the moving gradient background, status and
/// subtitles. Tap anywhere to send / interrupt / cancel.
struct LiveChatView: View {
    @ObservedObject var session: LiveSession
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var store: ChatHistoryStore
    let close: () -> Void

    init(session: LiveSession, store: ChatHistoryStore, close: @escaping () -> Void) {
        self._session = ObservedObject(wrappedValue: session)
        self._vm = ObservedObject(wrappedValue: session.vm)
        self._store = ObservedObject(wrappedValue: store)
        self.close = close
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // isolated in its own view so mic updates don't redraw the text
            LiveBackground(recognizer: session.recognizer, phase: session.phase)

            VStack(spacing: 0) {
                if let notice = vm.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }
                Spacer()
                LiveCaption(session: session, recognizer: session.recognizer, vm: vm, store: store)
                Spacer()
                controls
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.interrupt() }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    private var controls: some View {
        HStack {
            circleButton("xmark", label: "End live chat") {
                session.stop()
                close()
            }
            Spacer()
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            circleButton(actionIcon, label: "Interrupt") { session.interrupt() }
                .opacity(session.phase == .idle ? 0.3 : 1)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    private var hint: String {
        switch session.phase {
        case .listening: return "Tap anywhere to send"
        case .speaking: return "Tap to interrupt"
        case .thinking: return "Tap to cancel"
        case .idle: return ""
        }
    }

    private var actionIcon: String {
        switch session.phase {
        case .listening: return "arrow.up"
        case .speaking: return "hand.raised.fill"
        default: return "stop.fill"
        }
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .accessibilityLabel(label)
    }
}

/// Status line + subtitles.
private struct LiveCaption: View {
    @ObservedObject var session: LiveSession
    @ObservedObject var recognizer: SpeechRecognizer
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var store: ChatHistoryStore

    var body: some View {
        VStack(spacing: 16) {
            Text(status)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text(caption)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .truncationMode(.head)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var status: String {
        if let p = session.problem { return p }
        switch session.phase {
        case .listening: return "Listening"
        case .thinking: return vm.status ?? "Thinking"
        case .speaking: return "Speaking"
        case .idle: return "Starting"
        }
    }

    private var caption: String {
        switch session.phase {
        case .listening:
            return recognizer.transcript.isEmpty ? "Go ahead, I'm listening." : recognizer.transcript
        case .thinking, .speaking:
            if let last = store.currentMessages.last, last.role == .assistant {
                return SpeechService.clean(last.content)
            }
            return ""
        case .idle:
            return ""
        }
    }
}

/// The animated gradient. Reacts to your voice while listening.
private struct LiveBackground: View {
    @ObservedObject var recognizer: SpeechRecognizer
    let phase: LiveSession.Phase

    private var energy: Double {
        switch phase {
        case .listening: return Double(recognizer.level)
        case .speaking: return 0.6
        case .thinking: return 0.3
        case .idle: return 0.1
        }
    }

    var body: some View {
        LiveGradientBackground(energy: energy)
    }
}

// MARK: - Background

enum Palette {
    static let magenta = Color(red: 1.0, green: 0.18, blue: 0.77)
    static let violet = Color(red: 0.49, green: 0.23, blue: 1.0)
    static let blue = Color(red: 0.16, green: 0.42, blue: 1.0)
    static let coral = Color(red: 1.0, green: 0.36, blue: 0.43)
    static let amber = Color(red: 1.0, green: 0.77, blue: 0.25)
    static let night = Color(red: 0.05, green: 0.03, blue: 0.10)
    static let orb: [Color] = [magenta, violet, blue, coral, amber, magenta]
}

struct LiveGradientBackground: View {
    var energy: Double

    var body: some View {
        ZStack {
            if #available(iOS 18.0, *) {
                AnimatedMesh(energy: energy)
            } else {
                GeminiBackgroundGlow()
            }
            // keep text readable
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.15), .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

@available(iOS 18.0, *)
struct AnimatedMesh: View {
    var energy: Double

    var body: some View {
        // 30 fps is plenty for a slow gradient and much lighter than 120
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            MeshGradient(width: 3, height: 3,
                         points: points(Float(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))),
                         colors: [Palette.night, Palette.violet, Palette.night,
                                  Palette.magenta, Palette.coral, Palette.blue,
                                  Palette.amber, Palette.magenta, Palette.violet])
                .drawingGroup()
        }
    }

    private func points(_ t: Float) -> [SIMD2<Float>] {
        let e = Float(energy)
        let swing: Float = 0.12 + 0.18 * e
        let topX: Float = 0.5 + 0.25 * sin(t * 0.6)
        let leftY: Float = 0.5 + 0.2 * cos(t * 0.5)
        let rightY: Float = 0.5 + 0.2 * sin(t * 0.7)
        let bottomX: Float = 0.5 + 0.25 * cos(t * 0.55)
        let midX: Float = 0.5 + swing * sin(t * 0.9)
        let midY: Float = 0.5 + swing * cos(t * 1.1)
        return [
            SIMD2<Float>(0, 0), SIMD2<Float>(topX, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(0, leftY), SIMD2<Float>(midX, midY), SIMD2<Float>(1, rightY),
            SIMD2<Float>(0, 1), SIMD2<Float>(bottomX, 1), SIMD2<Float>(1, 1),
        ]
    }
}
