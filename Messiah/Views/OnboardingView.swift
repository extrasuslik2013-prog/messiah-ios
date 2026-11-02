import SwiftUI

/// First-launch setup: welcome, name, OpenRouter, Fish Audio (optional),
/// invite code, then "Welcome to Project Messiah, <name>".
struct OnboardingView: View {
    let finish: () -> Void

    enum Step: Int, CaseIterable { case welcome, name, openRouter, fish, invite, done }

    @ObservedObject private var owner = OwnerStore.shared
    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var name = UserDefaults.standard.string(forKey: AppSettings.userNameKey) ?? ""
    @State private var orKey = ""
    @State private var orModel = Self.initialModel
    @State private var fishKey = ""
    @State private var fishVoice = UserDefaults.standard.string(forKey: AppSettings.fishVoiceIDKey) ?? ""
    @State private var invite = ""
    @State private var checking = false
    @State private var error: String?
    @State private var shake: CGFloat = 0
    @State private var failures = 0
    @State private var lockedUntil: Date?
    @FocusState private var focused: Bool

    private let hasOpenRouterKey = Keychain.get(AppSettings.openRouterKeyName) != nil
    private let hasFishKey = Keychain.get(AppSettings.fishKeyName) != nil

    private static var initialModel: String {
        AppSettings.provider == .openrouter && !AppSettings.model.isEmpty ? AppSettings.model : "openai/gpt-4o-mini"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LiveGradientBackground(energy: step == .done ? 0.8 : 0.35)
                .animation(.easeInOut(duration: 1.2), value: step)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    // MARK: - Layout

    @ViewBuilder
    private var topBar: some View {
        HStack {
            if step != .welcome && step != .done {
                Button { back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .accessibilityLabel("Back")
                Spacer()
                HStack(spacing: 6) {
                    ForEach([Step.name, .openRouter, .fish, .invite], id: \.self) { s in
                        Capsule()
                            .fill(s.rawValue <= step.rawValue ? Color.white : Color.white.opacity(0.25))
                            .frame(width: s == step ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .frame(height: 44)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .name: nameStep
        case .openRouter: openRouterStep
        case .fish: fishStep
        case .invite: inviteStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            OnboardingOrb()
                .frame(width: 130, height: 130)
                .rise(0)
            Text("Hello.")
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .rise(0.25)
            Text("I'm Messiah. Let's get you set up.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .rise(0.5)
            primaryButton("Get started") { go(.name) }
                .padding(.top, 36)
                .rise(0.8)
        }
    }

    private var nameStep: some View {
        card(title: "What should I call you?",
             subtitle: "Messiah will use your name when it talks to you.") {
            field("Your name", text: $name, caps: .words)
                .textContentType(.givenName)
                .submitLabel(.continue)
                .onSubmit(nameNext)
            primaryButton("Continue", disabled: trimmed(name).isEmpty, action: nameNext)
        }
    }

    private var openRouterStep: some View {
        card(title: "Connect OpenRouter",
             subtitle: "Messiah thinks with models on OpenRouter. Create a key at openrouter.ai/keys and paste it here.") {
            field(hasOpenRouterKey ? "Key saved. Paste to replace" : "OpenRouter API key", text: $orKey, secure: true)
            field("Model (e.g. openai/gpt-4o-mini)", text: $orModel)
            primaryButton("Continue", disabled: trimmed(orKey).isEmpty && !hasOpenRouterKey, action: saveOpenRouter)
            Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                Label("Get a key", systemImage: "arrow.up.right.square")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var fishStep: some View {
        card(title: "Give Messiah a voice",
             subtitle: "Optional. Add a Fish Audio key for a natural voice, or skip to use the iPhone voice.") {
            field(hasFishKey ? "Key saved. Paste to replace" : "Fish Audio API key", text: $fishKey, secure: true)
            field("Voice ID (optional)", text: $fishVoice)
            primaryButton("Continue", disabled: trimmed(fishKey).isEmpty && !hasFishKey, action: saveFish)
            Button("Skip for now") { go(.invite) }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var inviteStep: some View {
        if owner.isOwner {
            card(title: "Owner device",
                 subtitle: "This iPhone owns Project Messiah, so no invite code is needed.") {
                Image(systemName: "crown.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(LinearGradient(colors: [Palette.amber, Palette.coral],
                                                    startPoint: .top, endPoint: .bottom))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                primaryButton("Continue") { go(.done) }
            }
        } else {
            card(title: "Enter your invite code",
                 subtitle: "Project Messiah is invite-only. Ask the owner for a code; each one works for 5 minutes.") {
                TextField("XXXXX-XXXXX", text: $invite)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1)))
                    .foregroundStyle(.white)
                    .onChange(of: invite) { _, v in
                        let f = InviteCodes.format(v)
                        if f != v { invite = f }
                    }
                    .onSubmit(checkInvite)
                primaryButton("Unlock", disabled: InviteCodes.clean(invite).count != 10, action: checkInvite)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 10) {
            OnboardingOrb()
                .frame(width: 96, height: 96)
                .rise(0)
                .padding(.bottom, 14)
            Text("Welcome to")
                .font(.title2.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .rise(0.2)
            Text("Project Messiah")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Palette.magenta, Palette.coral, Palette.amber],
                                                startPoint: .leading, endPoint: .trailing))
                .rise(0.5)
            Text(trimmed(name))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .rise(0.9)
            primaryButton("Enter Messiah", action: finish)
                .padding(.top, 44)
                .rise(1.5)
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.6)
        .lineLimit(2)
    }

    // MARK: - Building blocks

    private func card<C: View>(title: String, subtitle: String, @ViewBuilder _ fields: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .rise(0.05)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .rise(0.15)
            VStack(spacing: 12) { fields() }
                .padding(.top, 6)
                .rise(0.28)
            if let error {
                Text(error)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.65))
                    .transition(.opacity)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .modifier(Shake(amount: shake))
        .animation(.easeOut(duration: 0.2), value: error)
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool = false,
                       caps: TextInputAutocapitalization = .never) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textInputAutocapitalization(caps)
        .autocorrectionDisabled()
        .focused($focused)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1)))
        .foregroundStyle(.white)
    }

    private func primaryButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if checking { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(Capsule().fill(LinearGradient(colors: [Palette.magenta, Palette.coral],
                                                      startPoint: .leading, endPoint: .trailing)))
            .shadow(color: Palette.magenta.opacity(0.45), radius: 16, y: 6)
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(PressScale())
        .disabled(disabled || checking)
    }

    // MARK: - Actions

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func go(_ next: Step) {
        focused = false
        error = nil
        forward = next.rawValue > step.rawValue
        withAnimation(.spring(response: 0.6, dampingFraction: 0.88)) { step = next }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        go(prev)
    }

    private func fail(_ message: String) {
        error = message
        withAnimation(.linear(duration: 0.45)) { shake += 1 }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func nameNext() {
        let n = trimmed(name)
        guard !n.isEmpty else { return }
        UserDefaults.standard.set(n, forKey: AppSettings.userNameKey)
        go(.openRouter)
    }

    private func saveOpenRouter() {
        let key = trimmed(orKey)
        let model = trimmed(orModel).isEmpty ? "openai/gpt-4o-mini" : trimmed(orModel)
        let commit = {
            if !key.isEmpty { Keychain.set(key, for: AppSettings.openRouterKeyName) }
            UserDefaults.standard.set(ProviderKind.openrouter.rawValue, forKey: AppSettings.providerKey)
            UserDefaults.standard.set(model, forKey: AppSettings.modelKey)
            go(.fish)
        }
        guard !key.isEmpty else { commit(); return }
        checking = true
        error = nil
        Task {
            let result = await Self.checkOpenRouter(key)
            checking = false
            if result == .rejected {
                fail("OpenRouter didn't accept that key. Check it and try again.")
            } else {
                commit()
            }
        }
    }

    private func saveFish() {
        let key = trimmed(fishKey)
        if !key.isEmpty { Keychain.set(key, for: AppSettings.fishKeyName) }
        let voice = trimmed(fishVoice)
        if !voice.isEmpty { UserDefaults.standard.set(voice, forKey: AppSettings.fishVoiceIDKey) }
        UserDefaults.standard.set(SpeechProvider.fish.rawValue, forKey: AppSettings.speechProviderKey)
        go(.invite)
    }

    private func checkInvite() {
        if let until = lockedUntil, until > Date() {
            fail("Too many tries. Wait \(Int(until.timeIntervalSinceNow) + 1) seconds.")
            return
        }
        if InviteCodes.isValid(invite) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            go(.done)
            return
        }
        failures += 1
        if failures >= 5 {
            failures = 0
            lockedUntil = Date().addingTimeInterval(60)
            fail("Too many wrong codes. Try again in a minute.")
        } else {
            fail("That code is wrong or has expired. Ask the owner for a new one.")
        }
    }

    private enum KeyCheck { case ok, rejected, unreachable }

    private static func checkOpenRouter(_ key: String) async -> KeyCheck {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return .unreachable }
        if http.statusCode == 401 || http.statusCode == 403 { return .rejected }
        return (200..<300).contains(http.statusCode) ? .ok : .unreachable
    }
}

/// Slowly turning, breathing color orb.
struct OnboardingOrb: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Palette.orb, center: .center, angle: .degrees(t * 40)))
                    .blur(radius: 22)
                    .opacity(0.9)
                Circle()
                    .fill(AngularGradient(colors: Palette.orb, center: .center, angle: .degrees(-t * 60)))
                    .padding(16)
                Circle()
                    .fill(.white.opacity(0.22))
                    .blur(radius: 12)
                    .padding(36)
            }
            .scaleEffect(1 + 0.05 * sin(t * 1.6))
        }
        .allowsHitTesting(false)
    }
}

/// Fades, lifts and un-blurs a view in after a delay.
private struct Rise: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .blur(radius: shown ? 0 : 8)
            .onAppear {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(delay)) { shown = true }
            }
    }
}

extension View {
    fileprivate func rise(_ delay: Double) -> some View { modifier(Rise(delay: delay)) }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(amount * .pi * 4), y: 0))
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Owner-only: issue invite codes that work for 5 minutes.
struct InviteAdminView: View {
    @State private var code: String?
    @State private var expires = Date()

    var body: some View {
        Form {
            Section {
                if let code {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        let left = max(0, Int(expires.timeIntervalSince(tl.date).rounded(.up)))
                        VStack(spacing: 8) {
                            Text(code)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                                .opacity(left > 0 ? 1 : 0.4)
                            Text(left > 0 ? String(format: "Expires in %d:%02d", left / 60, left % 60) : "Expired")
                                .font(.subheadline)
                                .foregroundStyle(left > 0 ? Color.secondary : Color.red)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    Button { UIPasteboard.general.string = code } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: "Your Project Messiah invite code: \(code) (works for 5 minutes)") {
                        Label("Share code", systemImage: "square.and.arrow.up")
                    }
                }
                Button(action: issue) {
                    Label(code == nil ? "Issue invite code" : "Issue a new code", systemImage: "key.fill")
                }
            } footer: {
                Text("A code unlocks Messiah on a new install for 5 minutes after you issue it. Only this owner iPhone can issue codes.")
            }
        }
        .navigationTitle("Invite codes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func issue() {
        let now = Date()
        code = InviteCodes.issue(at: now)
        expires = now.addingTimeInterval(InviteCodes.lifetime)
    }
}
