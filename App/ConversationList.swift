import SwiftUI

struct ChatDestination: Hashable {
    let conversation: Conversation
    var parent: UUID?
    var focus: UUID?
    var sequence: Int64?
}

struct ConversationList: View {
    enum Panel: String, Identifiable {
        case newMessage, activity, search
        var id: Self { self }
        var title: String {
            switch self {
            case .newMessage: "New message"
            case .activity: "Activity"
            case .search: "Search messages"
            }
        }
    }

    let store: WorkspaceStore
    let user: UUID
    let workspace: Workspace
    let people: [UUID: String]
    @State private var conversations: [Conversation] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var panel: Panel?
    @State private var destination: ChatDestination?

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    action(.newMessage, icon: "square.and.pencil", title: "New DM")
                    action(.search, icon: "magnifyingglass", title: "Search")
                    action(.activity, icon: "bell", title: "Activity")
                }
            }
            section("Channels", direct: false)
            section("Direct messages", direct: true)
            if loaded && conversations.isEmpty && failure == nil {
                Text("No conversations yet. Start a direct message above.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(workspace.name)
        .overlay {
            if conversations.isEmpty && (!loaded || failure != nil) {
                if let failure {
                    ContentUnavailableView {
                        Label("Conversations unavailable", systemImage: "wifi.slash")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Loading conversations")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(item: $destination) { route in
            ChatView(store: store, user: user, workspace: workspace, conversation: route.conversation,
                     people: people, parentID: route.parent, focusID: route.focus, focusSequence: route.sequence)
        }
        .sheet(item: $panel) { section in
            WorkspacePanel(store: store, user: user, workspace: workspace, people: people,
                           panel: section, open: open)
        }
    }

    private func action(_ section: Panel, icon: String, title: String) -> some View {
        Button { panel = section } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(section.title)
    }

    @ViewBuilder private func section(_ name: String, direct: Bool) -> some View {
        let rows = conversations.filter { $0.isDirect == direct }
        if !rows.isEmpty {
            Section(name) {
                ForEach(rows) { conversation in
                    Button { destination = ChatDestination(conversation: conversation) } label: {
                        Label(conversation.title(user: user, people: people),
                              systemImage: direct ? "bubble.left" : "number")
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private func load() async {
        do {
            let rows = if store.isDemo { store.demoConversations }
                else { try await store.api.conversations(workspace: workspace.id) }
            try Task.checkCancellation()
            conversations = rows
            failure = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            conversations = []
            failure = message(for: error)
        }
    }

    private func open(_ id: UUID, parent: UUID?, focus: UUID?, sequence: Int64?) async throws {
        if !conversations.contains(where: { $0.id == id }) { await load() }
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            throw WorkspaceError.status(403)
        }
        panel = nil
        destination = ChatDestination(conversation: conversation, parent: parent, focus: focus, sequence: sequence)
    }
}

private struct WorkspacePanel: View {
    let store: WorkspaceStore
    let user: UUID
    let workspace: Workspace
    let people: [UUID: String]
    let panel: ConversationList.Panel
    let open: (UUID, UUID?, UUID?, Int64?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [ChatInventory.Entry] = []
    @State private var loading = false
    @State private var opening = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(.secondary) }
                if panel == .newMessage {
                    ForEach(teammates, id: \.key) { person in
                        Button { Task { await startDM(person.key) } } label: {
                            Label(person.value, systemImage: "person.crop.circle")
                        }
                        .disabled(opening)
                    }
                    if teammates.isEmpty { Text("No teammates found.").foregroundStyle(.secondary) }
                } else if loading {
                    ProgressView()
                } else {
                    ForEach(entries) { entry in
                        Button { Task { await openEntry(entry) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if let kind = entry.notification {
                                    Label(kind == "dm" ? "Direct message" : kind.capitalized,
                                          systemImage: entry.seenAt == nil ? "circle.fill" : "circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(ChatView.displayText(entry.body)).lineLimit(3)
                            }
                        }
                        .disabled(opening)
                    }
                    if entries.isEmpty && failure == nil {
                        Text(panel == .activity ? "You’re caught up." :
                                (query.isEmpty ? "Type to search your workspace." : "No messages found."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .modifier(PanelSearch(enabled: panel != .activity, query: $query))
            .task(id: query) { await load() }
            .refreshable { await load() }
        }
    }

    private var teammates: [(key: UUID, value: String)] {
        people.filter { $0.key != user && (query.isEmpty || $0.value.localizedCaseInsensitiveContains(query)) }
            .sorted { ($0.value.localizedLowercase, $0.key.uuidString) < ($1.value.localizedLowercase, $1.key.uuidString) }
    }

    private func startDM(_ recipient: UUID) async {
        guard !opening else { return }
        opening = true
        failure = nil
        defer { opening = false }
        do {
            let id: UUID
            if store.isDemo {
                if let existing = store.demoConversations.first(where: { $0.dmLow == recipient || $0.dmHigh == recipient }) {
                    id = existing.id
                } else {
                    id = UUID()
                    store.demoConversations.append(.init(id: id, name: "Direct conversation",
                                                         kind: "dm", dmLow: user, dmHigh: recipient))
                }
            } else {
                id = try await store.api.startDM(workspace: workspace.id, recipient: recipient)
            }
            try await open(id, nil, nil, nil)
        } catch { failure = message(for: error) }
    }

    private func load() async {
        guard panel != .newMessage else { return }
        failure = nil
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard panel == .activity || !term.isEmpty else {
            entries = []
            loading = false
            return
        }
        loading = true
        do {
            let matches: [ChatInventory.Entry]
            if store.isDemo {
                matches = store.demoConversations.flatMap { conversation in
                    Demo.rootRows(conversation, store: store).filter {
                        !$0.agent && (panel == .activity ? conversation.isDirect : $0.body.localizedCaseInsensitiveContains(term))
                    }.map { row in
                        .init(id: row.id, channelId: conversation.id, parentId: nil, body: row.body,
                              notification: panel == .activity ? "dm" : nil, seenAt: nil)
                    }
                }
            } else {
                if panel == .search { try await Task.sleep(for: .milliseconds(250)) }
                matches = try await store.api.inventory(workspace: workspace.id,
                    section: panel == .activity ? "activity" : "search", query: term).messages
            }
            try Task.checkCancellation()
            entries = matches
            loading = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            entries = []
            failure = message(for: error)
            loading = false
        }
    }

    private func openEntry(_ entry: ChatInventory.Entry) async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do {
            if panel == .activity && !store.isDemo && entry.seenAt == nil {
                try? await store.api.markSeen(entry)
            }
            try await open(entry.channelId, entry.parentId, entry.id, entry.sequence)
        } catch { failure = message(for: error) }
    }
}

private struct PanelSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $query, prompt: "Search") } else { content }
    }
}
