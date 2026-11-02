import SwiftUI
import AVFoundation

@main
struct MessiahApp: App {
    @StateObject private var store: ChatHistoryStore
    @StateObject private var chat: ChatViewModel
    @StateObject private var hybrid = HybridStore.shared
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppSettings.onboardedKey) private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = ChatHistoryStore()
        _store = StateObject(wrappedValue: store)
        _chat = StateObject(wrappedValue: ChatViewModel(store: store))
        UserDefaults.standard.register(defaults: Sfx.defaults)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if onboarded {
                    SidebarShell(store: store) {
                        // rebuilt after an Updater pack so new colors and text show at once
                        ChatView(vm: chat, store: store)
                            .id(hybrid.revision)
                    }
                    .transition(.opacity)
                } else {
                    OnboardingView {
                        withAnimation(.easeInOut(duration: 0.7)) { onboarded = true }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
            }
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: UpdateServer.shared.start()
                case .background: UpdateServer.shared.stop()
                default: break
                }
            }
            .onAppear { UpdateServer.shared.start() }
            .alert("Messiah was updated", isPresented: Binding(
                get: { hybrid.pendingAnnouncement != nil },
                set: { if !$0 { hybrid.pendingAnnouncement = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(hybrid.pendingAnnouncement ?? "")
            }
        }
    }
}
