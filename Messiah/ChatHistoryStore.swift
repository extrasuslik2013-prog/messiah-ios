import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, system }
    var id = UUID()
    var role: Role
    var content: String
    var isError = false
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "New chat"
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
}

/// All chats, saved as JSON in Application Support so they survive restarts.
@MainActor
final class ChatHistoryStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedID: UUID?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("messiah_chats.json")
    }()

    init() {
        load()
        // open on a fresh chat, like ChatGPT
        if let first = conversations.first, first.messages.isEmpty {
            selectedID = first.id
        } else {
            let chat = Conversation()
            conversations.insert(chat, at: 0)
            selectedID = chat.id
        }
    }

    var current: Conversation? { conversations.first { $0.id == selectedID } }
    var currentMessages: [ChatMessage] { current?.messages ?? [] }

    func messages(in id: UUID) -> [ChatMessage] {
        conversations.first { $0.id == id }?.messages ?? []
    }

    /// New chat; reuses the current one if it is still empty.
    func newChat() {
        if let cur = current, cur.messages.isEmpty { return }
        // drop any other leftover empty chats
        conversations.removeAll { $0.messages.isEmpty }
        let chat = Conversation()
        conversations.insert(chat, at: 0)
        selectedID = chat.id
        save()
    }

    func select(_ id: UUID) {
        guard id != selectedID else { return }
        let leaving = selectedID
        selectedID = id
        // forget the chat we left if nothing was ever said in it
        if let leaving, let c = conversations.first(where: { $0.id == leaving }), c.messages.isEmpty {
            conversations.removeAll { $0.id == leaving }
        }
    }

    func append(_ message: ChatMessage, to id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.append(message)
        conversations[i].updatedAt = Date()
        if conversations[i].title == "New chat", message.role == .user {
            conversations[i].title = Self.makeTitle(message.content)
        }
        if i != 0 {
            let chat = conversations.remove(at: i)
            conversations.insert(chat, at: 0)
        }
        save()
    }

    func setContent(_ content: String, isError: Bool = false, message mid: UUID, in id: UUID, persist: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }),
              let j = conversations[i].messages.firstIndex(where: { $0.id == mid }) else { return }
        conversations[i].messages[j].content = content
        conversations[i].messages[j].isError = isError
        if persist { save() }
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[i].title = t.isEmpty ? "New chat" : t
        save()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedID == id {
            let chat = Conversation()
            conversations.insert(chat, at: 0)
            selectedID = chat.id
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = saved.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save() {
        let snapshot = conversations.filter { !$0.messages.isEmpty }
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func makeTitle(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }
}
