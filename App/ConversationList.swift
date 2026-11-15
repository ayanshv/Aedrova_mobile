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
    var onboardingGoal: MobileOnboardingGoal? = nil
    var didFinishGuide: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @AccessibilityFocusState private var sidebarFocused: Bool
    @AccessibilityFocusState private var toggleFocused: Bool
    @State private var conversations: [Conversation] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var failure: String?
    @State private var panel: Panel?
    @State private var destination: ChatDestination?
    @State private var sidebarOpen = false
    @State private var showingAccount = false
    @State private var guideDismissed = false
    @State private var showingTeamInvite = false

    private var visibleGuide: MobileOnboardingGoal? { guideDismissed ? nil : onboardingGoal }
    @State private var unread: [UUID: Int] = [:]
    @State private var syncRevision = 0
    @State private var pendingWake: Task<Void, Never>?
    @State private var lastDirectoryRefresh: ContinuousClock.Instant?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                conversationContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(sidebarOpen)

                if sidebarOpen {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea(edges: .bottom)
                        .onTapGesture { setSidebar(false) }
                        .accessibilityHidden(true)
                        .transition(reduceMotion ? .identity : .opacity)
                        .zIndex(1)

                    sidebar
                        .frame(width: min(340, geometry.size.width * 0.86))
                        .frame(maxHeight: .infinity)
                        .background { MobileTheme.canvas.ignoresSafeArea(edges: .bottom) }
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.15), radius: 14, x: 5)
                        .transition(reduceMotion ? .identity : .move(edge: .leading))
                        .accessibilityElement(children: .contain)
                        .accessibilityAction(.escape) { setSidebar(false) }
                        .simultaneousGesture(DragGesture(minimumDistance: 18).onEnded { drag in
                            let direction: CGFloat = layoutDirection == .rightToLeft ? 1 : -1
                            if drag.translation.width * direction > 48
                                && abs(drag.translation.width) > abs(drag.translation.height) {
                                setSidebar(false)
                            }
                        })
                        .zIndex(2)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                if let goal = visibleGuide, destination != nil, !sidebarOpen {
                    FirstWorkspaceGuide(goal: goal, close: {
                        guideDismissed = true
                        didFinishGuide()
                    }) {
                        if goal == .catchUp {
                            panel = .search
                        } else {
                            setSidebar(true)
                        }
                    }
                }
            }
        }
        .aedrovaScreen(MobileTheme.surface)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: destination?.conversation.id) { old, new in
            old != nil && new != nil
        }
        .task {
            if let cached = store.cache.conversations(workspace.id) {
                applyConversations(cached)
            }
            await load()
        }
        .task(id: scene) {
            guard scene == .active, !store.isDemo else { return }
            await listenForUpdates()
        }
        .task(id: UnreadRefresh(scene: scene, revision: syncRevision)) {
            guard scene == .active, !store.isDemo else { return }
            if syncRevision > 0 {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            while !Task.isCancelled {
                await refreshUnread()
                let now = ContinuousClock().now
                if sidebarOpen && (lastDirectoryRefresh.map { $0.duration(to: now) >= .seconds(15) } ?? true) {
                    await load()
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onDisappear {
            pendingWake?.cancel()
            pendingWake = nil
        }
        .sheet(item: $panel) { section in
            WorkspacePanel(store: store, user: user, workspace: workspace, people: people,
                           panel: section, syncRevision: syncRevision, open: open, openDM: openDM)
        }
        .task {
            guard onboardingGoal != nil, !store.isDemo else { return }
            if (try? await store.api.canInvite(workspace: workspace.id, user: user)) == true,
               !Task.isCancelled, store.user == user {
                showingTeamInvite = true
            }
        }
        .sheet(isPresented: $showingTeamInvite) {
            TeamInviteSheet(api: store.api, workspace: workspace)
        }
    }

    private var header: some View {
        let title = destination?.conversation.title(user: user, people: people) ?? workspace.name

        return HStack {
            Button { setSidebar(!sidebarOpen) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.backward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MobileTheme.link)
                        .accessibilityHidden(true)
                    HStack(spacing: 4) {
                        if destination?.conversation.isDirect == false {
                            Text("#")
                                .foregroundStyle(MobileTheme.link)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .foregroundStyle(MobileTheme.ink)
                                .lineLimit(1)
                            if let conversation = destination?.conversation {
                                let topic = conversation.topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                let context = topic.isEmpty ? workspace.name : topic
                                Text(store.isDemo ? "Local demo · " + context : context)
                                    .font(.caption)
                                    .foregroundStyle(MobileTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .font(.headline)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(AedrovaPressStyle())
            .accessibilityLabel(title)
            .accessibilityHint(sidebarOpen ? "Hides the channel sidebar" : "Opens the channel sidebar")
            .accessibilityFocused($toggleFocused)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
        .background(MobileTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(MobileTheme.line).frame(height: 1) }
    }

    @ViewBuilder private var conversationContent: some View {
        if let route = destination {
            ChatView(store: store, user: user, workspace: workspace, conversation: route.conversation,
                     people: people, parentID: route.parent, focusID: route.focus, focusSequence: route.sequence,
                     sidebarVisible: sidebarOpen || panel != nil, syncRevision: syncRevision,
                     onboardingGoal: visibleGuide, didRead: { Task { await refreshUnread() } })
                .id(route)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !loaded && failure == nil {
                    ProgressView("Loading conversations")
                } else if let failure {
                    AedrovaState(title: "Couldn’t load conversations", detail: failure, symbol: "wifi.slash")
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(AedrovaTextAction())
                } else {
                    AedrovaState(title: "Choose a conversation",
                                 detail: "Open the sidebar to browse channels and direct messages.", symbol: "sidebar.left")
                    Button("Show channels") { setSidebar(true) }
                        .buttonStyle(AedrovaTextAction())
                }
            }
            .padding(24)
        }
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                HStack {
                    Button { dismiss() } label: {
                        Label("Workspaces", systemImage: "square.grid.2x2")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(MobileTheme.link)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    Spacer(minLength: 8)
                    Button { showingAccount = true } label: {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(MobileTheme.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Account")
                }
                .buttonStyle(AedrovaPressStyle())

                HStack(spacing: 12) {
                    AedrovaInitials(name: workspace.name, size: 46, emphasized: true)
                    Text(workspace.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($sidebarFocused)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                layout {
                    action(.newMessage, icon: "square.and.pencil", title: "New DM")
                    action(.search, icon: "magnifyingglass", title: "Search")
                    action(.activity, icon: "bell", title: "Activity")
                }

                section("Channels", direct: false)
                section("Direct messages", direct: true)

                if let failure {
                    AedrovaState(title: "Couldn’t refresh conversations", detail: failure, symbol: "wifi.slash")
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(AedrovaTextAction())
                } else if !loaded {
                    ProgressView("Loading conversations")
                } else if conversations.isEmpty {
                    AedrovaState(title: "No conversations yet",
                                 detail: "Use New DM to message a teammate.", symbol: "bubble.left")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await load() }
        .sheet(isPresented: $showingAccount) { AccountSettingsSheet(store: store) }
    }

    private func setSidebar(_ visible: Bool) {
        guard sidebarOpen != visible else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            sidebarOpen = visible
        }
        sidebarFocused = visible
        toggleFocused = !visible
        if visible && !store.isDemo {
            Task {
                let now = ContinuousClock().now
                if lastDirectoryRefresh.map({ $0.duration(to: now) >= .seconds(10) }) ?? true { await load() }
            }
        }
    }

    private func select(_ route: ChatDestination) {
        destination = route
        setSidebar(false)
    }

    private func applyConversations(_ rows: [Conversation]) {
        conversations = rows
        loaded = true
        if let current = destination, rows.contains(where: { $0.id == current.conversation.id }) { return }
        let first = rows.first(where: { !$0.isDirect && $0.name.caseInsensitiveCompare("general") == .orderedSame })
            ?? rows.first(where: { !$0.isDirect }) ?? rows.first
        destination = first.map { ChatDestination(conversation: $0) }
    }

    private func action(_ section: Panel, icon: String, title: String) -> some View {
        Button {
            setSidebar(false)
            panel = section
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.body.weight(.medium)).accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.medium))
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(section == .newMessage ? MobileTheme.link : MobileTheme.ink)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(section == .newMessage ? MobileTheme.selection : MobileTheme.surface,
                        in: RoundedRectangle(cornerRadius: 13))
            .contentShape(.rect)
        }
        .buttonStyle(AedrovaPressStyle())
        .accessibilityLabel(section.title)
    }

    @ViewBuilder private func section(_ name: String, direct: Bool) -> some View {
        let rows = conversations.filter { conversation in
            let peer = conversation.dmLow == user ? conversation.dmHigh : conversation.dmLow
            return conversation.isDirect == direct && peer.map { !store.blockedPeople.contains($0) } != false
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(name).font(.subheadline.weight(.semibold))
                    .foregroundStyle(MobileTheme.secondary)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 4) {
                    ForEach(rows) { conversation in
                        let title = conversation.title(user: user, people: people)
                        let selected = destination?.conversation.id == conversation.id
                        let count = unread[conversation.id, default: 0]
                        Button { select(ChatDestination(conversation: conversation)) } label: {
                            HStack(spacing: 12) {
                                if direct {
                                    AedrovaInitials(name: title)
                                } else {
                                    AedrovaGlyph(symbol: "number", highlighted: true)
                                }
                                Text(title)
                                    .font(.body.weight(count > 0 ? .semibold : .medium))
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(MobileTheme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if count > 0 {
                                    Text(count > 99 ? "99+" : String(count))
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(MobileTheme.link)
                                        .accessibilityHidden(true)
                                } else if selected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(MobileTheme.link)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(minHeight: 52)
                            .background(selected ? MobileTheme.selection : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(.rect)
                        }
                        .buttonStyle(AedrovaPressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityValue(count > 0 ? "\(count) unread" : "")
                    }
                }
                .padding(.vertical, 4)
                .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 15))
            }
        }
    }

    private struct UnreadRefresh: Equatable {
        let scene: ScenePhase
        let revision: Int
    }

    private func refreshUnread() async {
        guard !store.isDemo, scene == .active, store.user == user else { return }
        do {
            let counts = try await store.api.unreadCounts()
            try Task.checkCancellation()
            guard store.user == user else { return }
            unread = Dictionary(counts.map { ($0.channelId, $0.unread) }, uniquingKeysWith: { _, new in new })
        } catch {
            if !Task.isCancelled && (error as? WorkspaceError)?.isAccessFailure == true { unread = [:] }
        }
    }

    private func listenForUpdates() async {
        let api = store.api
        var delay = 1
        while !Task.isCancelled && store.user == user {
            let started = ContinuousClock().now
            do {
                let connection = try await api.realtimeConnection(for: user)
                try await RealtimeWakeups.listen(connection, renew: { try await api.realtimeToken(for: user) }) {
                    guard !Task.isCancelled, store.user == user else { return }
                    guard pendingWake == nil else { return }
                    pendingWake = Task {
                        defer { pendingWake = nil }
                        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                        guard scene == .active, store.user == user else { return }
                        syncRevision += 1
                    }
                }
            } catch {
                if Task.isCancelled || (error as? WorkspaceError)?.isAccessFailure == true { return }
            }
            if started.duration(to: ContinuousClock().now) > .seconds(30) { delay = 1 }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            delay = min(delay * 2, 30)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let rows = if store.isDemo { store.demoConversations }
                else { try await store.api.conversations(workspace: workspace.id) }
            try Task.checkCancellation()
            guard store.user == user else { return }
            if !store.isDemo { store.cache.storeConversations(rows, workspace: workspace.id) }
            applyConversations(rows)
            lastDirectoryRefresh = ContinuousClock().now
            failure = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, store.user == user else { return }
            if (error as? WorkspaceError)?.isAccessFailure == true {
                store.cache.forget(workspace.id)
                conversations = []
                destination = nil
            }
            failure = message(for: error)
        }
    }

    private func openDM(_ recipient: UUID) async throws {
        let existing = conversations.first {
            $0.kind == "dm" && (($0.dmLow == user && $0.dmHigh == recipient) ||
                               ($0.dmHigh == user && $0.dmLow == recipient))
        }
        if let existing {
            panel = nil
            select(ChatDestination(conversation: existing))
            return
        }

        let id = if store.isDemo { UUID() }
            else { try await store.api.startDM(workspace: workspace.id, recipient: recipient) }
        try Task.checkCancellation()
        guard store.user == user else { throw WorkspaceError.signIn }
        let conversation = Conversation(id: id, name: "Direct conversation", kind: "dm", dmLow: user, dmHigh: recipient)
        if store.isDemo { store.demoConversations.append(conversation) }
        if !conversations.contains(where: { $0.id == id }) { conversations.append(conversation) }
        panel = nil
        select(ChatDestination(conversation: conversation))
    }

    private func open(_ id: UUID, parent: UUID?, focus: UUID?, sequence: Int64?) async throws {
        if !conversations.contains(where: { $0.id == id }) { await load() }
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            throw WorkspaceError.status(403)
        }
        panel = nil
        select(ChatDestination(conversation: conversation, parent: parent, focus: focus, sequence: sequence))
    }
}

private struct WorkspacePanel: View {
    let store: WorkspaceStore
    let user: UUID
    let workspace: Workspace
    let people: [UUID: String]
    let panel: ConversationList.Panel
    let syncRevision: Int
    let open: (UUID, UUID?, UUID?, Int64?) async throws -> Void
    let openDM: (UUID) async throws -> Void
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
                            HStack(spacing: 12) {
                                AedrovaInitials(name: person.value)
                                Text(person.value).foregroundStyle(MobileTheme.ink)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .disabled(opening)
                        .listRowBackground(MobileTheme.surface)
                        .listRowSeparatorTint(MobileTheme.line)
                    }
                    if teammates.isEmpty { Text("No teammates found.").foregroundStyle(.secondary) }
                } else {
                    if loading { ProgressView().accessibilityLabel("Updating results") }
                    ForEach(entries) { entry in
                        Button { Task { await openEntry(entry) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if let kind = entry.notification {
                                    Label(kind == "dm" ? "Direct message" : kind.capitalized,
                                          systemImage: entry.seenAt == nil ? "circle.fill" : "circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(ChatView.displayText(entry.body)).lineLimit(3)
                                    .foregroundStyle(MobileTheme.ink)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .disabled(opening)
                        .listRowBackground(MobileTheme.surface)
                        .listRowSeparatorTint(MobileTheme.line)
                    }
                    if entries.isEmpty && failure == nil && !loading {
                        Text(panel == .activity ? "You’re caught up." :
                                (query.isEmpty ? "Type to search your workspace." : "No messages found."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aedrovaPanelRows()
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .modifier(PanelSearch(enabled: panel != .activity, query: $query))
            .task(id: query) { await load() }
            .onChange(of: syncRevision) { _, _ in
                if panel == .activity { Task { await load() } }
            }
            .refreshable { await load() }
        }
    }

    private var teammates: [(key: UUID, value: String)] {
        people.filter {
            $0.key != user && !store.blockedPeople.contains($0.key)
                && (query.isEmpty || $0.value.localizedCaseInsensitiveContains(query))
        }
            .sorted { ($0.value.localizedLowercase, $0.key.uuidString) < ($1.value.localizedLowercase, $1.key.uuidString) }
    }

    private func startDM(_ recipient: UUID) async {
        guard !opening else { return }
        opening = true
        failure = nil
        defer { opening = false }
        do { try await openDM(recipient) }
        catch { failure = message(for: error) }
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
        if panel == .search && !store.isDemo {
            entries = store.cache.search(term, workspace: workspace.id).filter(isVisible)
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
            guard store.user == user else { return }
            entries = matches.filter(isVisible)
            loading = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, store.user == user else { return }
            if (error as? WorkspaceError)?.isAccessFailure == true {
                store.cache.forget(workspace.id)
                entries = []
            }
            failure = message(for: error)
            loading = false
        }
    }

    private func isVisible(_ entry: ChatInventory.Entry) -> Bool {
        entry.senderId.map { !store.blockedPeople.contains($0) } ?? true
    }

    private func openEntry(_ entry: ChatInventory.Entry) async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do {
            try await open(entry.channelId, entry.parentId, entry.id, entry.sequence)
            if panel == .activity && !store.isDemo && entry.seenAt == nil {
                Task { try? await store.api.markSeen(entry) }
            }
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
