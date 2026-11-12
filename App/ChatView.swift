import SwiftUI

struct ChatView: View {
    struct Row: Identifiable {
        let id: UUID
        let author: String
        let body: String
        let createdAt: Date
        var agent = false
        var pending = false
    }

    struct Draft {
        let id = UUID()
        let body: String
    }

    @Environment(\.scenePhase) private var scene
    let store: WorkspaceStore
    let user: UUID
    let workspace: Workspace
    let conversation: Conversation
    let people: [UUID: String]
    var parentID: UUID? = nil
    var focusID: UUID? = nil
    var focusSequence: Int64? = nil
    var threadStarter: Row? = nil
    @State private var thread: Row?
    @State private var showMentions = false
    @State private var mentions: [ChatInventory.Member] = []
    @State private var didFocus = false
    @State private var showingLatest = false
    @State private var rows: [Row] = []
    @State private var draft = ""
    @State private var pending: Draft?
    @State private var sending = false
    @State private var loading = false
    @State private var loaded = false
    @State private var loadError: String?
    @State private var sendError: String?

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let threadStarter {
                        messageRow(threadStarter)
                        Divider()
                    }
                    if showingEarlier {
                        Button("Jump to latest") {
                            showingLatest = true
                        }
                        .buttonStyle(.bordered)
                    }
                    if let loadError {
                        Text(loadError).font(.footnote).foregroundStyle(.secondary)
                    } else if loaded && rows.isEmpty {
                        Text(parentID == nil ? "Start the conversation." : "Start the thread.").foregroundStyle(.secondary)
                    } else if !loaded {
                        ProgressView("Loading messages")
                    }
                    ForEach(rows) { row in
                        messageRow(row)
                            .padding(focusID == row.id ? 8 : 0)
                            .background {
                                if focusID == row.id {
                                    RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.12))
                                }
                            }
                            .id(row.id)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(parentID == nil ? .bottom : .top)
            .refreshable { await load() }
            .onChange(of: rows.last?.id) { _, last in
                if !didFocus, let focusID, rows.contains(where: { $0.id == focusID }) {
                    didFocus = true
                    scroll.scrollTo(focusID, anchor: .center)
                } else if showingLatest || (focusID == nil && (rows.count <= 1 || sending)) {
                    if let last { scroll.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { if !showingEarlier { composer } }
        .navigationTitle(parentID == nil ? conversation.title(user: user, people: people) : "Thread")
        .sheet(item: $thread) { row in
            NavigationStack {
                ChatView(store: store, user: user, workspace: workspace, conversation: conversation,
                         people: people, parentID: row.id, threadStarter: row)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { thread = nil } } }
            }
        }
        .sheet(isPresented: $showMentions) {
            MentionPicker(store: store, user: user, workspace: workspace, conversation: conversation) { person in
                if !mentions.contains(where: { $0.id == person.id }) { mentions.append(person) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: PollingState(scene: scene, latest: showingLatest)) {
            guard scene == .active else { return }
            while !Task.isCancelled {
                await load()
                if showingEarlier { return }
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
            }
        }
    }

    private struct PollingState: Equatable {
        let scene: ScenePhase
        let latest: Bool
    }

    private var showingEarlier: Bool { focusSequence != nil && !showingLatest }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sendError { Text(sendError).font(.footnote).foregroundStyle(.secondary) }
            if !mentions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(mentions) { person in
                            Button {
                                mentions.removeAll { $0.id == person.id }
                            } label: { Label("@" + person.displayName, systemImage: "xmark.circle") }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Remove mention of " + person.displayName)
                        }
                    }
                }
                .disabled(sending)
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { showMentions = true } label: {
                    Image(systemName: "at").font(.title3).frame(minWidth: 36, minHeight: 36)
                }
                .accessibilityLabel("Mention teammate")
                .disabled(sending)
                TextField(parentID == nil ? "Message" : "Reply", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(sending)
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .accessibilityLabel("Send message")
                .disabled(sending || bodyText.isEmpty || wireBody.unicodeScalars.count > 10_000)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var bodyText: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var wireBody: String {
        let tags = mentions.map { person in
            let name = person.displayName.filter { !"<>|\n\r".contains($0) }
            return "<@\(person.id.uuidString.lowercased())|\(name.isEmpty ? "Teammate" : name)>"
        }
        return (tags + [bodyText]).joined(separator: " ")
    }

    static func displayText(_ body: String) -> String {
        body.replacingOccurrences(of: #"<@[A-Fa-f0-9-]{36}\|([^>]+)>"#, with: "@$1", options: .regularExpression)
    }

    private func messageRow(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if row.agent && row.author == "Aedrova" {
                    Image("Brand").resizable().scaledToFit().padding(5)
                } else if row.agent {
                    Image(systemName: "sparkle").font(.subheadline.weight(.medium))
                } else {
                    Text(row.author.prefix(1).uppercased()).font(.subheadline.weight(.semibold))
                }
            }
            .frame(width: 34, height: 34)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(row.author).font(.subheadline.weight(.semibold))
                    if row.pending { Text("Sending").font(.caption).foregroundStyle(.secondary) }
                    else if row.createdAt != .distantPast {
                        Text(row.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(Self.displayText(row.body)).textSelection(.enabled)
                if parentID == nil && !row.agent && !row.pending {
                    Button { thread = row } label: {
                        Label("Reply in thread", systemImage: "bubble.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            if store.isDemo {
                if let parentID { rows = store.demoMessages[parentID] ?? [] }
                else { rows = Demo.rootRows(conversation, store: store) }
            } else {
                let before = showingEarlier ? focusSequence.map { $0 + 1 } : nil
                let messageRows: [Message]
                let agentRows: [AgentReply]
                if let before {
                    messageRows = try await store.api.messages(conversation: conversation.id, parent: parentID, before: before)
                    agentRows = []
                } else {
                    async let messages = store.api.messages(conversation: conversation.id, parent: parentID)
                    async let replies = store.api.replies(workspace: workspace.id, conversation: conversation.id, parent: parentID)
                    (messageRows, agentRows) = try await (messages, replies)
                }
                try Task.checkCancellation()
                let server = messageRows.filter { $0.unsentAt == nil }.map {
                    Row(id: $0.id, author: $0.senderId == user ? "You" : people[$0.senderId] ?? "Teammate",
                        body: $0.body, createdAt: timestamp($0.createdAt))
                } + agentRows.map {
                    Row(id: $0.id, author: $0.agentName, body: $0.body, createdAt: timestamp($0.createdAt), agent: true)
                }
                let existing = Set(server.map(\.id))
                rows = (server + rows.filter { $0.pending && !existing.contains($0.id) })
                    .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            }
            loaded = true
            loadError = nil
        } catch is CancellationError {
        } catch let failure {
            if case WorkspaceError.status(403) = failure { rows = [] }
            if case WorkspaceError.status(401) = failure { rows = [] }
            if case WorkspaceError.signIn = failure { rows = [] }
            loadError = message(for: failure)
        }
    }

    private func timestamp(_ value: String) -> Date {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601)) ?? .distantPast
    }

    private func send() async {
        let text = wireBody
        guard !sending, !bodyText.isEmpty, text.unicodeScalars.count <= 10_000 else { return }
        let request = pending.flatMap { $0.body == text ? $0 : nil } ?? Draft(body: text)
        pending = request
        sending = true
        sendError = nil
        let created = Date.now
        rows.removeAll { $0.id == request.id }
        rows.append(Row(id: request.id, author: "You", body: text, createdAt: created, pending: true))
        defer { sending = false }
        do {
            if !store.isDemo {
                try await store.api.send(id: request.id, conversation: conversation.id, body: text, parent: parentID)
            }
            if let index = rows.firstIndex(where: { $0.id == request.id }) { rows[index].pending = false }
            if store.isDemo { store.demoMessages[parentID ?? conversation.id] = rows }
            draft = ""
            mentions = []
            pending = nil
            await load()
        } catch {
            rows.removeAll { $0.id == request.id && $0.pending }
            sendError = "Delivery couldn’t be confirmed. Your message is still in the composer."
        }
    }
}

enum Demo {
    static let user = UUID()
    static let teammate = UUID()
    static let designer = UUID()
    static let workspace = Workspace(id: UUID(), name: "Studio North")
    static let conversations = [
        Conversation(id: UUID(), name: "general", kind: "channel", dmLow: nil, dmHigh: nil),
        Conversation(id: UUID(), name: "launch", kind: "channel", dmLow: nil, dmHigh: nil),
        Conversation(id: UUID(), name: "direct", kind: "dm", dmLow: user, dmHigh: teammate)
    ]
    static let people = [
        Person(workspaceId: workspace.id, userId: teammate, displayName: "Maya"),
        Person(workspaceId: workspace.id, userId: designer, displayName: "Jamie")
    ]

    @MainActor static func rootRows(_ conversation: Conversation, store: WorkspaceStore) -> [ChatView.Row] {
        if let rows = store.demoMessages[conversation.id] { return rows }
        let rows = Demo.rows(for: conversation)
        store.demoMessages[conversation.id] = rows
        return rows
    }

    static func rows(for conversation: Conversation) -> [ChatView.Row] {
        if conversation.isDirect {
            guard conversation.dmLow == teammate || conversation.dmHigh == teammate else { return [] }
            return [.init(id: UUID(), author: "Maya", body: "Can you take a look at the new welcome screen?",
                          createdAt: Date.now)]
        }
        return [
            .init(id: UUID(), author: "Maya", body: "The onboarding preview is ready. Can someone check the first run?",
                  createdAt: Date.now),
            .init(id: UUID(), author: "Aedrova", body: "I checked the welcome flow. The next review is the workspace invite step.",
                  createdAt: Date.now, agent: true)
        ]
    }
}


private struct MentionPicker: View {
    let store: WorkspaceStore
    let user: UUID
    let workspace: Workspace
    let conversation: Conversation
    let select: (ChatInventory.Member) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var members: [ChatInventory.Member] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(.secondary) }
                if loading { ProgressView() }
                ForEach(members.filter {
                    $0.id != user && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query))
                }.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }) { person in
                    Button {
                        select(person)
                        dismiss()
                    } label: {
                        Label(person.displayName, systemImage: "person.crop.circle")
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a teammate")
            .navigationTitle("Mention teammate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                defer { loading = false }
                do {
                    if store.isDemo {
                        members = Demo.people.filter {
                            !conversation.isDirect || $0.userId == conversation.dmLow || $0.userId == conversation.dmHigh
                        }.map { .init(userId: $0.userId, displayName: $0.displayName) }
                    } else {
                        members = try await store.api.inventory(workspace: workspace.id,
                                                                section: "people", channel: conversation.id).people
                    }
                } catch { failure = message(for: error) }
            }
        }
    }
}
