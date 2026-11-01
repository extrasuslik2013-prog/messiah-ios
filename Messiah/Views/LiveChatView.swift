import SwiftUI

/// Full-screen voice mode with a moving gradient and a glowing orb that
/// reacts to your voice.
struct LiveChatView: View {
    @ObservedObject var session: LiveSession
    @ObservedObject var recognizer: SpeechRecognizer
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var store: ChatHistoryStore
    let close: () -> Void

    init(session: LiveSession, store: ChatHistoryStore, close: @escaping () -> Void) {
        self._session = ObservedObject(wrappedValue: session)
        self._recognizer = ObservedObject(wrappedValue: session.recognizer)
        self._vm = ObservedObject(wrappedValue: session.vm)
        self._store = ObservedObject(wrappedValue: store)
        self.close = close
    }

    private var energy: Double {
        switch session.phase {
        case .listening: return Double(recognizer.level)
        case .speaking: return 0.7
        case .thinking: return 0.35
        case .idle: return 0.1
        }
    }

    private var statusText: String {
        if let p = session.problem { return p }
        switch session.phase {
        case .listening: return recognizer.transcript.isEmpty ? "Listening" : "Listening…"
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LiveGradientBackground(energy: energy)
                .animation(.easeOut(duration: 0.25), value: energy)

            VStack(spacing: 28) {
                Spacer()

                LiveOrb(energy: energy, phase: session.phase)
                    .frame(width: 210, height: 210)
                    .contentShape(Circle())
                    .onTapGesture { session.interrupt() }

                VStack(spacing: 14) {
                    GeminiShimmerText(text: statusText)
                        .multilineTextAlignment(.center)
                    Text(caption)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .truncationMode(.head)
                        .padding(.horizontal, 28)
                        .animation(.easeOut(duration: 0.2), value: caption)
                }
                .frame(minHeight: 160, alignment: .top)

                Spacer()

                HStack {
                    circleButton("xmark", label: "End live chat") {
                        session.stop()
                        close()
                    }
                    Spacer()
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    circleButton(actionIcon, label: "Interrupt") { session.interrupt() }
                        .opacity(session.phase == .idle ? 0.3 : 1)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    private var hint: String {
        switch session.phase {
        case .listening: return "Tap the orb to send"
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
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Orb

struct LiveOrb: View {
    var energy: Double
    var phase: LiveSession.Phase

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let pulse = orbPulse(t)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Palette.orb, center: .center, angle: .degrees(t * 35)))
                    .blur(radius: 40)
                    .opacity(0.9)
                    .scaleEffect(1.3 + pulse * 1.4)

                Circle()
                    .fill(AngularGradient(colors: Palette.orb, center: .center, angle: .degrees(-t * 55)))
                    .overlay(
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear],
                                                     center: UnitPoint(x: 0.35, y: 0.3),
                                                     startRadius: 2, endRadius: 120))
                    )
                    .overlay(
                        Circle().fill(AngularGradient(colors: Palette.orb.reversed(), center: .center,
                                                      angle: .degrees(t * 80)))
                            .blendMode(.screen)
                            .opacity(0.45)
                            .blur(radius: 12)
                    )
                    .clipShape(Circle())
                    .scaleEffect(1 + pulse)
            }
        }
    }

    private func orbPulse(_ t: Double) -> CGFloat {
        switch phase {
        case .listening: return CGFloat(energy) * 0.28 + 0.02 * CGFloat(sin(t * 2))
        case .speaking: return 0.07 + 0.06 * CGFloat(sin(t * 7)) * CGFloat(abs(sin(t * 1.7)))
        case .thinking: return 0.04 * CGFloat(sin(t * 3))
        case .idle: return 0
        }
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
                GeminiBackgroundGlow().opacity(1)
            }
            // keep text readable
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.55)],
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
        TimelineView(.animation) { tl in
            MeshGradient(width: 3, height: 3, points: points(Float(tl.date.timeIntervalSinceReferenceDate)),
                         colors: [Palette.night, Palette.violet, Palette.night,
                                  Palette.magenta, Palette.coral, Palette.blue,
                                  Palette.amber, Palette.magenta, Palette.violet])
        }
    }

    private func points(_ t: Float) -> [SIMD2<Float>] {
        let e = Float(energy)
        let swing: Float = 0.12 + 0.18 * e
        let speed: Float = 1 + 1.5 * e
        let topX: Float = 0.5 + 0.25 * sin(t * 0.6 * speed)
        let leftY: Float = 0.5 + 0.2 * cos(t * 0.5 * speed)
        let rightY: Float = 0.5 + 0.2 * sin(t * 0.7 * speed)
        let bottomX: Float = 0.5 + 0.25 * cos(t * 0.55 * speed)
        let midX: Float = 0.5 + swing * sin(t * 0.9 * speed)
        let midY: Float = 0.5 + swing * cos(t * 1.1 * speed)
        return [
            SIMD2<Float>(0, 0), SIMD2<Float>(topX, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(0, leftY), SIMD2<Float>(midX, midY), SIMD2<Float>(1, rightY),
            SIMD2<Float>(0, 1), SIMD2<Float>(bottomX, 1), SIMD2<Float>(1, 1),
        ]
    }
}
