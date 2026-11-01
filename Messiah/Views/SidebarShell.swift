import SwiftUI

/// ChatGPT-style layout: ☰ on the left opens a pull-out sidebar with every
/// chat; the button on the right starts a new chat (replaces "Clear").
struct SidebarShell<Content: View>: View {
    @ObservedObject var store: ChatHistoryStore
    let content: () -> Content

    init(store: ChatHistoryStore, @ViewBuilder content: @escaping () -> Content) {
        self._store = ObservedObject(wrappedValue: store)
        self.content = content
    }

    @State private var isOpen = false
    @State private var drag: CGFloat = 0
    @State private var showSettings = false

    private let width: CGFloat = 300

    var body: some View {
        let offset = min(max((isOpen ? width : 0) + drag, 0), width)

        ZStack(alignment: .leading) {
            mainColumn
                .offset(x: offset)
                .overlay {
                    Color.black
                        .opacity(0.4 * offset / width)
                        .offset(x: offset)
                        .ignoresSafeArea()
                        .allowsHitTesting(offset > 0)
                        .onTapGesture { setOpen(false) }
                }

            SidebarView(store: store,
                        close: { setOpen(false) },
                        openSettings: { setOpen(false); showSettings = true })
                .frame(width: width)
                .offset(x: offset - width)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { g in
                    let w = g.translation.width, h = g.translation.height
                    guard abs(w) > abs(h) * 1.5 || drag != 0 else { return }
                    if !isOpen && w < 0 { return }
                    if drag == 0 { hideKeyboard() }
                    drag = w
                }
                .onEnded { g in
                    guard drag != 0 else { return }
                    let projected = (isOpen ? width : 0) + g.predictedEndTranslation.width
                    setOpen(projected > width / 2)
                }
        )
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Button { hideKeyboard(); setOpen(true) } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open chats")

                Spacer()
                Text("Messiah").font(.headline)
                Spacer()

                Button { store.newChat() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("New chat")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)

            content()
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func setOpen(_ open: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isOpen = open
            drag = 0
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct SidebarView: View {
    @ObservedObject var store: ChatHistoryStore
    let close: () -> Void
    let openSettings: () -> Void

    init(store: ChatHistoryStore, close: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self._store = ObservedObject(wrappedValue: store)
        self.close = close
        self.openSettings = openSettings
    }

    @State private var search = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search)
            }
            .padding(10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .padding([.horizontal, .top], 14)

            Button { store.newChat(); close() } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)

            if sections.isEmpty {
                Text(search.isEmpty ? "No chats yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                Spacer()
            } else {
                List {
                    ForEach(sections, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.chats) { chat in row(chat) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 18)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
        }
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
        .alert("Rename chat", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Title", text: $renameText)
            Button("Save") { if let c = renaming { store.rename(c.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ chat: Conversation) -> some View {
        let selected = chat.id == store.selectedID
        return Button { store.select(chat.id); close() } label: {
            Text(chat.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color(.tertiarySystemFill) : Color.clear)
                .padding(.horizontal, 8)
        )
        .listRowSeparator(.hidden)
        .swipeActions {
            Button(role: .destructive) { store.delete(chat.id) } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button { renameText = chat.title; renaming = chat } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { store.delete(chat.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// Today / Yesterday / Previous 7 days / Older
    private struct ChatGroup { let name: String; let chats: [Conversation] }

    private var sections: [ChatGroup] {
        let cal = Calendar.current
        let chats = store.conversations.filter { c in
            !c.messages.isEmpty && (search.isEmpty
                || c.title.localizedCaseInsensitiveContains(search)
                || c.messages.contains { $0.content.localizedCaseInsensitiveContains(search) })
        }
        var groups: [String: [Conversation]] = [:]
        for c in chats {
            let key: String
            if cal.isDateInToday(c.updatedAt) { key = "Today" }
            else if cal.isDateInYesterday(c.updatedAt) { key = "Yesterday" }
            else if (cal.dateComponents([.day], from: c.updatedAt, to: Date()).day ?? 99) < 7 { key = "Previous 7 days" }
            else { key = "Older" }
            groups[key, default: []].append(c)
        }
        return ["Today", "Yesterday", "Previous 7 days", "Older"].compactMap { k in
            groups[k].map { ChatGroup(name: k, chats: $0) }
        }
    }
}
