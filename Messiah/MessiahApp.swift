import SwiftUI
import AVFoundation

@main
struct MessiahApp: App {
    @StateObject private var store: ChatHistoryStore
    @StateObject private var chat: ChatViewModel

    init() {
        let store = ChatHistoryStore()
        _store = StateObject(wrappedValue: store)
        _chat = StateObject(wrappedValue: ChatViewModel(store: store))
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    var body: some Scene {
        WindowGroup {
            SidebarShell(store: store) {
                ChatView(vm: chat, store: store)
            }
        }
    }
}
