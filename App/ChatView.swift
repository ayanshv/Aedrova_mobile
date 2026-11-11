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
    @State private var rows: [Row] = []
    @State private var draft = ""
    @State private var pending: Draft?
    @State private var sending = false
    @State private var loading = false
    @State private var loaded = false
    @State private var loadError: String?
    @State private var sendError: String?
    @State private var demoLoaded = false

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let loadError {
                        Text(loadError).font(.footnote).foregroundStyle(.secondary)
                    } else if loaded && rows.isEmpty {
                        Text("Start the conversation.").foregroundStyle(.secondary)
                    } else if !loaded {
                        ProgressView("Loading messages")
                    }
                    ForEach(rows) { row in
                        messageRow(row).id(row.id)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .refreshable { await load() }
            .onChange(of: rows.last?.id) { _, last in
                if let last { scroll.scrollTo(last, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(conversation.title(user: user, people: people))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scene) {
            guard scene == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sendError { Text(sendError).font(.footnote).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(sending)
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .accessibilityLabel("Send message")
                .disabled(sending || bodyText.isEmpty || bodyText.unicodeScalars.count > 10_000)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var bodyText: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                }
                Text(row.body).textSelection(.enabled)
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
                if !demoLoaded {
                    rows = Demo.rows(for: conversation)
                    demoLoaded = true
                }
            } else {
                async let messages = store.api.messages(conversation: conversation.id)
                async let replies = store.api.replies(workspace: workspace.id, conversation: conversation.id)
                let (messageRows, agentRows) = try await (messages, replies)
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
        let text = bodyText
        guard !sending, !text.isEmpty, text.unicodeScalars.count <= 10_000 else { return }
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
                try await store.api.send(id: request.id, conversation: conversation.id, body: text)
            }
            if let index = rows.firstIndex(where: { $0.id == request.id }) { rows[index].pending = false }
            draft = ""
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
    static let workspace = Workspace(id: UUID(), name: "Studio North")
    static let conversations = [
        Conversation(id: UUID(), name: "general", kind: "channel", dmLow: nil, dmHigh: nil),
        Conversation(id: UUID(), name: "launch", kind: "channel", dmLow: nil, dmHigh: nil),
        Conversation(id: UUID(), name: "direct", kind: "dm", dmLow: user, dmHigh: teammate)
    ]
    static let people = [Person(workspaceId: workspace.id, userId: teammate, displayName: "Maya")]

    static func rows(for conversation: Conversation) -> [ChatView.Row] {
        if conversation.isDirect {
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
