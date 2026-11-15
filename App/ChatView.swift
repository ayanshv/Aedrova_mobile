import SwiftUI
import UIKit

struct ChatView: View {
    struct Row: Identifiable {
        let id: UUID
        let author: String
        let body: String
        let createdAt: Date
        var agent = false
        var pending = false
        var sequence: Int64? = nil
        var isOwn = false
        var canFollowUp = false
        var senderID: UUID? = nil
    }

    struct Draft {
        let id = UUID()
        let body: String
    }

    struct ComposerDraft {
        var text = ""
        var mentions: [ChatInventory.Member] = []
    }

    struct FailedSend {
        let request: Draft
        let message: String
    }

    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    let store: WorkspaceStore
    let user: UUID
    let workspace: Workspace
    let conversation: Conversation
    let people: [UUID: String]
    var parentID: UUID? = nil
    var focusID: UUID? = nil
    var focusSequence: Int64? = nil
    var threadStarter: Row? = nil
    var sidebarVisible = false
    var syncRevision = 0
    var onboardingGoal: MobileOnboardingGoal? = nil
    var didRead: (() -> Void)? = nil
    @State private var thread: Row?
    @State private var moderation: ChatModeration?
    @State private var moderationNotice: String?
    @State private var showModerationNotice = false

    private struct ChatModeration: Identifiable {
        let row: Row
        let block: Bool
        var id: UUID { row.id }
    }

    private static let reportReasons = [
        ("Harassment or hate", "harassment"), ("Threats or violence", "threat"),
        ("Spam or scams", "spam"), ("Sexual content", "sexual_content"), ("Something else", "other")
    ]

    @State private var showMentions = false
    @State private var followUpReply: Row?
    @State private var followUpStarter = ""
    @State private var didFocus = false
    @State private var showingLatest = false
    @State private var savedRows: [Row] = []
    private var rows: [Row] {
        let outgoing = store.outgoingMessages[scope] ?? [:]
        let visibleRows = savedRows.filter { row in
            guard let sender = row.senderID else { return true }
            return !store.blockedPeople.contains(sender)
        }
        guard !outgoing.isEmpty else { return visibleRows }
        let savedIDs = Set(visibleRows.map(\.id))
        return (visibleRows + outgoing.values.filter { !savedIDs.contains($0.id) })
            .sorted(by: Self.messageOrder)
    }

    private static func messageOrder(_ left: Row, _ right: Row) -> Bool {
        (left.createdAt, left.id.uuidString) < (right.createdAt, right.id.uuidString)
    }
    @State private var snapshot: ChatSnapshot?
    @State private var loading = false
    @State private var loaded = false
    @State private var loadError: String?
    @State private var pollDelay = 8
    @State private var typers: [UUID] = []
    @State private var participants: [UUID: ChatInventory.Member] = [:]
    @State private var lastParticipantRefresh: ContinuousClock.Instant?
    @State private var agentPhases: [WorkspaceAPI.PeerAgentProgress] = []
    @State private var typingAt: ContinuousClock.Instant?
    @State private var typingReported = false
    @State private var typingUpdate: Task<Void, Never>?
    @State private var older: [Message] = []
    @State private var hasMoreHistory = true
    @State private var loadingOlder = false
    @State private var historyError: String?
    @State private var atEnd = false
    @State private var readCursor: Int64?
    @State private var unreadBoundary: Int64?
    @State private var incoming = 0
    @State private var repeatRefresh = false
    @State private var jumpRequested = false
    @State private var lastSync: Date?

    var body: some View {
        ScrollViewReader { scroll in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let threadStarter, threadStarter.senderID.map({ !store.blockedPeople.contains($0) }) != false {
                            messageRow(threadStarter)
                            Divider()
                        }
                        if showingEarlier {
                            Button("Jump to latest") {
                                jumpRequested = true
                                showingLatest = true
                            }
                            .buttonStyle(AedrovaTextAction())
                        }
                        if canLoadOlder {
                            Button(loadingOlder ? "Loading earlier messages" : "Load earlier messages") {
                                let anchor = rows.first?.id
                                Task {
                                    if await loadEarlier(), let anchor { scroll.scrollTo(anchor, anchor: .top) }
                                }
                            }
                            .buttonStyle(AedrovaTextAction())
                            .disabled(loadingOlder)
                            if let historyError {
                                Text(historyError).font(.footnote).foregroundStyle(MobileTheme.muted)
                            }
                        }
                        if loaded && rows.isEmpty && loadError == nil {
                            AedrovaState(title: parentID == nil ? "Start the conversation" : "Start the thread",
                                         detail: "Send a message to get started.", symbol: "bubble.left")
                        } else if !loaded && loadError == nil {
                            ProgressView("Loading messages")
                        }
                        let messages = rows
                        let unreadID = firstUnread
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, row in
                            if beginsDay(index, in: messages) {
                                Text(dayLabel(row.createdAt))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(MobileTheme.muted)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            if row.id == unreadID {
                                Label("New messages", systemImage: "circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(MobileTheme.link)
                            }
                            messageRow(row, grouped: groupsWithPrevious(index, in: messages, unreadID: unreadID),
                                       showThreadAction: !groupsWithPrevious(index + 1, in: messages, unreadID: unreadID))
                                .padding(focusID == row.id ? 8 : 0)
                                .background {
                                    if focusID == row.id {
                                        RoundedRectangle(cornerRadius: 10).fill(MobileTheme.selection)
                                    }
                                }
                                .transition(reduceMotion ? .identity : .offset(y: 10).combined(with: .opacity))
                                .id(row.id)
                        }
                        Color.clear.frame(height: 1)
                            .id("latest-message")
                            .background {
                                GeometryReader { marker in
                                    Color.clear.preference(key: ChatEndVisible.self, value: {
                                        let frame = marker.frame(in: .named("chat-viewport"))
                                        return frame.maxY >= 0 && frame.maxY <= viewport.size.height + 1
                                    }())
                                }
                            }
                    }
                    .padding(16)
                }
                .coordinateSpace(name: "chat-viewport")
                .chatScrollAnchors(opensAtLatest: parentID == nil && focusID == nil)
                .refreshable { await load(forceFull: true) }
                .trackChatEnd { visible in
                    atEnd = visible
                    if visible { incoming = 0 }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atEnd && !rows.isEmpty && !showingEarlier {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                                scrollToLatest(scroll)
                            }
                        } label: {
                            let title = incoming == 0 ? "Jump to latest" : incoming == 1 ? "New message" : "New messages"
                            Label(title, systemImage: "arrow.down")
                        }
                        .buttonStyle(AedrovaTextAction())
                        .padding(12)
                    }
                }
            }
            .onChange(of: rows.last?.id) { previous, last in
                if !didFocus, let focusID, rows.contains(where: { $0.id == focusID }) {
                    didFocus = true
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        scroll.scrollTo(focusID, anchor: .center)
                    }
                } else if !showingEarlier && (jumpRequested || atEnd || sending ||
                                               (parentID == nil && previous == nil && focusID == nil)) {
                    if last != nil {
                        jumpRequested = false
                        withAnimation(sending && !reduceMotion ? .easeOut(duration: 0.20) : nil) {
                            scrollToLatest(scroll)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let loadError {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash").accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if lastSync != nil || !rows.isEmpty {
                            Text("Chat isn’t up to date").font(.subheadline.weight(.semibold))
                        }
                        Text(loadError).font(.caption)
                    }
                    Spacer(minLength: 0)
                    Button("Retry") { Task { await load(forceFull: true) } }
                        .buttonStyle(AedrovaTextAction())
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .foregroundStyle(MobileTheme.secondary)
                .background(MobileTheme.canvas)
                .accessibilityElement(children: .contain)
            }
        }
        .safeAreaInset(edge: .bottom) { if !showingEarlier { composer } }
        .navigationTitle(parentID == nil ? conversation.title(user: user, people: people) : "Thread")
        .aedrovaScreen(MobileTheme.surface)
        .sheet(item: $thread) { row in
            NavigationStack {
                ChatView(store: store, user: user, workspace: workspace, conversation: conversation,
                         people: people, parentID: row.id, threadStarter: row, syncRevision: syncRevision)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { thread = nil } } }
                    .toolbar(.visible, for: .navigationBar)
            }
        }
        .sheet(isPresented: $showMentions) {
            MentionPicker(store: store, user: user, workspace: workspace, conversation: conversation) { person in
                if !mentions.contains(where: { $0.id == person.id }) { mentions.append(person) }
            }
        }
        .task(id: user) { try? await store.refreshChatBlocks() }
        .confirmationDialog(moderation?.block == true ? "Block teammate?" : "Report message",
                            isPresented: Binding(get: { moderation != nil }, set: { if !$0 { moderation = nil } }),
                            titleVisibility: .visible, presenting: moderation) { action in
            if action.block {
                Button("Block", role: .destructive) { Task { await updateModeration(action) } }
            } else {
                ForEach(Self.reportReasons, id: \.1) { reason in
                    Button(reason.0) { Task { await updateModeration(action, reason: reason.1) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.block ? "Hide this teammate’s messages and prevent new direct messages between you." :
                "Aedrova Support receives the reason and a copy of this message.")
        }
        .alert(moderationNotice ?? "", isPresented: $showModerationNotice) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $followUpReply, onDismiss: {
            Task { await load(forceFull: false) }
        }) { reply in
            FollowUpSheet(store: store, user: user, scope: scope, reply: reply, starter: followUpStarter)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: sidebarVisible) { _, visible in
            if visible { composerFocused = false }
        }
        .task(id: peerSignalsEnabled) {
            typers = []
            agentPhases = []
            guard peerSignalsEnabled else { return }
            while !Task.isCancelled {
                do {
                    async let phases = store.api.peerAgentPhases(conversation: conversation.id, parent: parentID, user: user)
                    let peers = parentID == nil ? try await store.api.typingPeers(conversation: conversation.id, excluding: user) : []
                    let activePhases = try? await phases
                    try Task.checkCancellation()
                    typers = peers.filter { !store.blockedPeople.contains($0) }
                    agentPhases = activePhases ?? []
                    await refreshParticipants()
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    if Task.isCancelled { return }
                    typers = []
                    agentPhases = []
                    let delay = if case WorkspaceError.rateLimited(let seconds) = error { max(8, seconds) } else { 12 }
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        .onChange(of: presenceEnabled) { _, active in
            if !active { reportTyping(active: false) }
        }
        .onDisappear { reportTyping(active: false) }
        .onChange(of: syncRevision) { _, _ in
            guard scene == .active, !store.isDemo, !showingEarlier else { return }
            if loading { repeatRefresh = true }
            else { Task { await load(forceFull: false) } }
        }
        .task(id: ReadAttempt(sequence: readCandidate, lastSync: lastSync)) {
            guard let sequence = readCandidate else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard readCandidate == sequence else { return }
                try await store.api.markRead(conversation: conversation.id, sequence: sequence)
                try Task.checkCancellation()
                guard store.user == user else { return }
                readCursor = max(readCursor ?? 0, sequence)
                didRead?()
            } catch {}
        }
        .task(id: PollingState(scene: scene, latest: showingLatest)) {
            guard scene == .active else { return }
            if !showingEarlier, !loaded, let cached = store.cache.chat(scope) {
                snapshot = cached
                render(cached)
                loaded = true
            }
            while !Task.isCancelled {
                await load(forceFull: false)
                if showingEarlier { return }
                let delay = pollDelay
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }

    private func scrollToLatest(_ scroll: ScrollViewProxy) {
        if let last = rows.last {
            scroll.scrollTo(last.id, anchor: .bottom)
            scroll.scrollTo("latest-message", anchor: .bottom)
        }
    }

    private struct PollingState: Equatable {
        let scene: ScenePhase
        let latest: Bool
    }

    private var showingEarlier: Bool { focusSequence != nil && !showingLatest }

    private struct ReadAttempt: Equatable {
        let sequence: Int64?
        let lastSync: Date?
    }

    private var readCandidate: Int64? {
        guard !store.isDemo, scene == .active, atEnd, !sidebarVisible, thread == nil,
              !showMentions, followUpReply == nil, parentID == nil, !showingEarlier, loadError == nil,
              lastSync != nil, let readCursor, let cursor = snapshot?.cursor, cursor > readCursor else { return nil }
        return cursor
    }

    private var firstUnread: UUID? {
        guard let unreadBoundary else { return nil }
        return rows.first { ($0.sequence ?? 0) > unreadBoundary && !$0.isOwn }?.id
    }

    private var canLoadOlder: Bool {
        !store.isDemo && !showingEarlier && hasMoreHistory && (snapshot?.messages.count ?? 0) >= ChatSnapshot.pageSize
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func beginsDay(_ index: Int, in messages: [Row]) -> Bool {
        let date = messages[index].createdAt
        return date != .distantPast && (index == 0 || !Calendar.current.isDate(date, inSameDayAs: messages[index - 1].createdAt))
    }

    private func groupsWithPrevious(_ index: Int, in messages: [Row], unreadID: UUID?) -> Bool {
        guard index > 0, index < messages.count, !beginsDay(index, in: messages), messages[index].id != unreadID else { return false }
        let previous = messages[index - 1]
        let current = messages[index]
        let sameSender = current.senderID.map { $0 == previous.senderID }
            ?? (store.isDemo && current.author == previous.author)
        return sameSender && !current.agent && !previous.agent
            && current.createdAt.timeIntervalSince(previous.createdAt) < 120
    }

    private func loadEarlier() async -> Bool {
        guard !loadingOlder, let before = (older + (snapshot?.messages ?? [])).map(\.sequence).min() else { return false }
        loadingOlder = true
        historyError = nil
        defer { loadingOlder = false }
        do {
            let page = try await store.api.messages(conversation: conversation.id, parent: parentID, before: before)
            try Task.checkCancellation()
            guard store.user == user, let snapshot else { return false }
            older += page
            hasMoreHistory = page.count == ChatSnapshot.pageSize && older.count < 300
            render(snapshot)
            return !page.isEmpty
        } catch {
            if !Task.isCancelled {
                if (error as? WorkspaceError)?.isAccessFailure == true {
                    store.cache.forget(workspace.id)
                    snapshot = nil
                    older = []
                    savedRows = []
                    lastSync = nil
                    loadError = message(for: error)
                } else {
                    historyError = message(for: error)
                }
            }
            return false
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if peerSignalsEnabled, let progress = agentPhases.first(where: { activity in
                snapshot?.replies.contains(where: { $0.promptId == activity.promptId }) != true
            }) {
                HStack(spacing: 7) {
                    Image("AedrovaMark").resizable().scaledToFit().frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(agentActivityLabel(progress.phase)).font(.caption)
                    AedrovaActivityDots()
                }
                .foregroundStyle(MobileTheme.muted)
            }
            if presenceEnabled && !typers.isEmpty {
                HStack(spacing: 7) {
                    Text(typingLabel).font(.caption)
                    AedrovaActivityDots()
                }
                .foregroundStyle(MobileTheme.muted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(MobileTheme.control, in: RoundedRectangle(cornerRadius: 8))
            }
            if let deliveryError = store.failedSends[scope]?.message {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(deliveryError).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        if let failed {
                            Button("Retry") { Task { await send(retrying: failed) } }
                                .disabled(sending)
                            Button("Discard") {
                                store.failedSends[scope] = nil
                            }
                        }
                    }
                    if let failed {
                        Text(Self.displayText(failed.body)).font(.footnote)
                            .lineLimit(2).textSelection(.enabled)
                    }
                }
            }
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
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { showMentions = true } label: {
                    Image(systemName: "at").font(.body.weight(.medium))
                        .foregroundStyle(MobileTheme.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(AedrovaPressStyle())
                .accessibilityLabel("Mention teammate")

                TextField(parentID == nil ? "Message" : "Reply", text: draftText, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...5)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(MobileTheme.link)

                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        .foregroundStyle(canSend ? Color.white : MobileTheme.muted)
                        .frame(width: 44, height: 44)
                        .background(canSend ? MobileTheme.accent : MobileTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(AedrovaPressStyle())
                .accessibilityLabel("Send message")
                .disabled(!canSend)
            }
            .padding(4)
            .background(MobileTheme.canvas, in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(MobileTheme.line, lineWidth: 1) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(MobileTheme.surface)
    }

    private var canSend: Bool {
        !sending && failed == nil && !bodyText.isEmpty && wireBody.unicodeScalars.count <= 10_000
    }

    private var sending: Bool { store.activeSends.contains(scope) }
    private var failed: Draft? { store.failedSends[scope]?.request }

    private var draftText: Binding<String> {
        Binding(
            get: { store.composerDrafts[scope]?.text ?? "" },
            set: { text in
                store.composerDrafts[scope, default: ComposerDraft()].text = text
                reportTyping(active: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        )
    }

    private var mentions: [ChatInventory.Member] {
        get { store.composerDrafts[scope]?.mentions ?? [] }
        nonmutating set { store.composerDrafts[scope, default: ComposerDraft()].mentions = newValue }
    }

    private var bodyText: String { draftText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var presenceEnabled: Bool {
        peerSignalsEnabled && parentID == nil
    }

    private var peerSignalsEnabled: Bool {
        !store.isDemo && store.user == user && scene == .active
            && !sidebarVisible && !showingEarlier && thread == nil && !showMentions && followUpReply == nil
    }

    private func agentActivityLabel(_ phase: String) -> String {
        switch phase {
        case "context": "Agent is finding context"
        case "responding": "Agent is preparing a reply"
        default: "Agent is thinking"
        }
    }

    private func refreshParticipants() async {
        let clock = ContinuousClock()
        if let lastParticipantRefresh, lastParticipantRefresh.duration(to: clock.now) < .seconds(15) { return }
        lastParticipantRefresh = clock.now
        do {
            let roster = try await store.api.inventory(workspace: workspace.id, section: "people", channel: conversation.id).people
            guard !Task.isCancelled, store.user == user else { return }
            participants = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            if (error as? WorkspaceError)?.isAccessFailure == true { participants = [:] }
        }
    }

    private func displayName(_ person: UUID) -> String? { participants[person]?.displayName ?? people[person] }

    private func displayAuthor(_ row: Row) -> String {
        guard !row.isOwn, let sender = row.senderID else { return row.author }
        return displayName(sender) ?? row.author
    }

    private var typingLabel: String {
        if typers.count == 1 { return (displayName(typers[0]) ?? "A teammate") + " is typing" }
        if typers.count == 2, let first = displayName(typers[0]), let second = displayName(typers[1]) {
            return first + " and " + second + " are typing"
        }
        return "Teammates are typing"
    }

    private func reportTyping(active: Bool) {
        guard presenceEnabled || (!active && typingReported) else { return }
        let now = ContinuousClock().now
        if let last = typingAt, active && last.duration(to: now) < .seconds(3) { return }
        if !active && !typingReported { return }
        if active { typingAt = now }
        typingReported = active
        let previous = typingUpdate
        typingUpdate = Task {
            await previous?.value
            guard store.user == user else { return }
            try? await store.api.setTyping(conversation: conversation.id, active: active)
        }
    }

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

    @ViewBuilder private func onboardingReply(_ row: Row) -> some View {
        let hasReferences = row.body.range(
            of: #"(?i)\b(?:message|attachment|memory|meeting|agent-work|build-review):[a-f0-9-]{36}\b"#,
            options: .regularExpression
        ) != nil
        let detail = hasReferences
            ? "This reply includes source references. Review them alongside the conversation."
            : "Read this reply alongside the conversation for context."
        VStack(alignment: .leading, spacing: 6) {
            Label(detail, systemImage: hasReferences ? "link" : "lightbulb")
                .font(.footnote)
                .foregroundStyle(MobileTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if row.canFollowUp && !store.isDemo {
                Button(onboardingGoal == .build ? "Draft a review question" : "Draft a catch-up question") {
                    followUpStarter = onboardingGoal == .build
                        ? "What should I verify before starting this work?"
                        : "What decisions and open questions does this reply identify?"
                    followUpReply = row
                }
                .buttonStyle(AedrovaTextAction())
            }
        }
    }

    private func messageRow(_ row: Row, grouped: Bool = false, showThreadAction: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if grouped {
                Color.clear.frame(width: 34, height: 1).accessibilityHidden(true)
            } else if row.agent && row.author == "Aedrova" {
                Image("AedrovaMark").resizable().scaledToFit()
                    .frame(width: 34, height: 34).accessibilityHidden(true)
            } else if row.agent {
                AedrovaGlyph(symbol: "sparkle", size: 34)
            } else {
                ChatProfilePhoto(store: store, path: row.senderID.flatMap { participants[$0]?.avatarPath },
                                 name: displayAuthor(row), isOwn: row.isOwn)
            }
            VStack(alignment: .leading, spacing: 5) {
                if !grouped {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) { messageMetadata(row) }
                        VStack(alignment: .leading, spacing: 2) { messageMetadata(row) }
                    }
                }
                Text(Self.displayText(row.body))
                    .foregroundStyle(MobileTheme.ink)
                    .textSelection(.enabled)
                    .contextMenu {
                        if parentID == nil && !row.agent && !row.pending && !showThreadAction {
                            Button("Reply in thread", systemImage: "bubble.left") { thread = row }
                        }
                        if !store.isDemo && !row.agent && !row.pending && !row.isOwn && row.senderID != nil {
                            Button("Report message", systemImage: "flag") {
                                moderation = ChatModeration(row: row, block: false)
                            }
                            Button("Block teammate", systemImage: "hand.raised", role: .destructive) {
                                moderation = ChatModeration(row: row, block: true)
                            }
                        }
                    }
                let guidedReply = parentID == nil && onboardingGoal != nil && row.agent
                    && row.id == rows.last(where: { $0.agent })?.id
                if row.canFollowUp && !store.isDemo && !guidedReply {
                    Button {
                        followUpStarter = ""
                        followUpReply = row
                    } label: {
                        Label("Ask a follow-up", systemImage: "arrow.turn.up.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .tint(MobileTheme.link)
                    .padding(.top, 2)
                }
                if guidedReply { onboardingReply(row) }
                if row.pending {
                    HStack(spacing: 6) {
                        Text("Sending").font(.caption)
                        AedrovaActivityDots()
                    }
                    .foregroundStyle(MobileTheme.muted)
                }
                if showThreadAction && parentID == nil && !row.agent && !row.pending {
                    Button { thread = row } label: {
                        Label("Reply in thread", systemImage: "bubble.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .tint(MobileTheme.link)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func updateModeration(_ action: ChatModeration, reason: String? = nil) async {
        do {
            if action.block, let sender = action.row.senderID {
                let name = displayAuthor(action.row)
                try await store.setChatBlock(sender, workspace: workspace.id, name: name, blocked: true)
                typers.removeAll { $0 == sender }
                moderationNotice = "Teammate blocked"
            } else if let reason {
                _ = try await store.api.reportChatMessage(action.row.id, reason: reason)
                moderationNotice = "Report sent to Aedrova Support"
            }
        } catch {
            moderationNotice = "Couldn’t complete this action. Try again."
        }
        showModerationNotice = true
    }

    @ViewBuilder private func messageMetadata(_ row: Row) -> some View {
        Text(row.agent ? "\(row.author) · Agent" : displayAuthor(row))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MobileTheme.ink)
        if row.createdAt != .distantPast {
            Text(row.createdAt, style: .time).font(.caption).foregroundStyle(MobileTheme.muted)
        }
    }

    private var scope: ChatScope {
        ChatScope(workspace: workspace.id, channel: conversation.id, parent: parentID)
    }

    private func load(forceFull: Bool) async {
        guard !loading else { return }
        loading = true
        defer {
            loading = false
            if repeatRefresh {
                repeatRefresh = false
                if !Task.isCancelled && scene == .active { Task { await load(forceFull: false) } }
            }
        }
        do {
            if store.isDemo {
                if let parentID { savedRows = store.demoMessages[parentID] ?? [] }
                else { savedRows = Demo.rootRows(conversation, store: store) }
            } else if showingEarlier, let focusSequence {
                let upperBound = focusSequence == Int64.max ? focusSequence : focusSequence + 1
                let messages = try await store.api.messages(conversation: conversation.id,
                                                            parent: parentID, before: upperBound)
                try Task.checkCancellation()
                guard store.user == user else { return }
                render(.init(messages: messages, replies: [], checkedAt: ContinuousClock().now))
            } else {
                let now = ContinuousClock().now
                let previous = snapshot
                let freshSnapshot = previous.flatMap { $0.checkedAt.duration(to: now) < .seconds(24) ? $0 : nil }
                let cursor = forceFull ? nil : freshSnapshot?.cursor
                async let messages = store.api.messages(conversation: conversation.id, parent: parentID, after: cursor)
                async let replies = store.api.replies(workspace: workspace.id, conversation: conversation.id, parent: parentID)
                async let initialCursor = readCursor == nil && parentID == nil
                    ? try? store.api.lastRead(conversation: conversation.id) : nil
                let (page, agentRows, storedCursor) = try await (messages, replies, initialCursor)
                let updated: ChatSnapshot
                if let previous, cursor != nil, page.count < ChatSnapshot.pageSize {
                    updated = .init(messages: previous.merging(page), replies: agentRows, checkedAt: previous.checkedAt)
                } else {
                    let latest = cursor == nil ? page : try await store.api.messages(conversation: conversation.id, parent: parentID)
                    updated = .init(messages: latest, replies: agentRows, checkedAt: now)
                }
                try Task.checkCancellation()
                guard store.user == user else { return }
                if let storedCursor {
                    readCursor = max(readCursor ?? 0, storedCursor)
                    unreadBoundary = storedCursor
                }
                if let previous, !atEnd {
                    let known = Set(previous.messages.map(\.id))
                    incoming += updated.messages.filter {
                        !known.contains($0.id) && $0.senderId != user && $0.unsentAt == nil
                            && $0.sequence > (previous.cursor ?? 0)
                    }.count
                }
                snapshot = updated
                store.cache.storeChat(updated, scope: scope)
                if previous?.messages != updated.messages || previous?.replies != updated.replies
                    || store.outgoingMessages[scope] != nil || failed != nil {
                    render(updated)
                }
            }
            pollDelay = 8
            loaded = true
            lastSync = .now
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, store.user == user else { return }
            if (error as? WorkspaceError)?.isAccessFailure == true {
                store.cache.forget(workspace.id)
                snapshot = nil
                older = []
                lastSync = nil
                store.outgoingMessages[scope] = nil
                savedRows = []
            }
            if case WorkspaceError.rateLimited(let seconds) = error { pollDelay = max(8, seconds) }
            else { pollDelay = min(30, pollDelay * 2) }
            if let networkError = error as? URLError,
               [.notConnectedToInternet, .networkConnectionLost].contains(networkError.code) {
                loadError = "Connection lost. Reconnecting…"
            } else {
                loadError = message(for: error)
            }
        }
    }

    private func render(_ data: ChatSnapshot) {
        var outgoing = store.outgoingMessages[scope] ?? [:]
        for message in data.messages {
            outgoing[message.id] = nil
            if failed?.id == message.id {
                store.failedSends[scope] = nil
            }
        }
        let merged = Dictionary((older + data.messages).map { ($0.id, $0) }, uniquingKeysWith: { _, fresh in fresh })
        let server = merged.values.filter { $0.unsentAt == nil }.map {
            Row(id: $0.id, author: $0.senderId == user ? "You" : people[$0.senderId] ?? "Teammate",
                body: $0.body, createdAt: timestamp($0.createdAt), sequence: $0.sequence,
                isOwn: $0.senderId == user, senderID: $0.senderId)
        } + data.replies.map {
            Row(id: $0.id, author: $0.agentName, body: $0.body, createdAt: timestamp($0.createdAt),
                agent: true, canFollowUp: $0.supportsFollowUp)
        }
        savedRows = server.sorted(by: Self.messageOrder)
        store.outgoingMessages[scope] = outgoing.isEmpty ? nil : outgoing
    }

    private func timestamp(_ value: String) -> Date {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601)) ?? .distantPast
    }

    private func send(retrying retry: Draft? = nil) async {
        guard !sending, store.user == user else { return }
        let request: Draft
        if let retry {
            guard failed?.id == retry.id else { return }
            request = retry
        } else {
            let text = wireBody
            guard !bodyText.isEmpty, text.unicodeScalars.count <= 10_000 else { return }
            request = Draft(body: text)
            store.composerDrafts[scope] = nil
            reportTyping(active: false)
        }
        store.activeSends.insert(scope)
        store.failedSends[scope] = nil
        let row = Row(id: request.id, author: "You", body: request.body, createdAt: .now,
                      pending: true, isOwn: true, senderID: user)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
            store.outgoingMessages[scope, default: [:]][request.id] = row
        }
        defer {
            if store.user == user { store.activeSends.remove(scope) }
        }
        do {
            if !store.isDemo {
                try await store.api.send(id: request.id, conversation: conversation.id, body: request.body, parent: parentID)
            }
            guard store.user == user else { return }
            if store.isDemo {
                var delivered = row
                delivered.pending = false
                savedRows.append(delivered)
                store.demoMessages[parentID ?? conversation.id] = savedRows
                store.outgoingMessages[scope] = nil
            } else {
                store.outgoingMessages[scope]?[request.id]?.pending = false
                if loading { repeatRefresh = true }
                else { Task { await load(forceFull: false) } }
            }
        } catch {
            guard store.user == user else { return }
            let unresolved = store.outgoingMessages[scope]?.removeValue(forKey: request.id) != nil
            guard unresolved else { return }
            if store.outgoingMessages[scope]?.isEmpty == true { store.outgoingMessages[scope] = nil }
            let detail = if case WorkspaceError.rateLimited = error { message(for: error) }
                         else { "Delivery couldn’t be confirmed." }
            store.failedSends[scope] = FailedSend(request: request, message: detail)
        }
    }

}

private struct ChatProfilePhoto: View {
    let store: WorkspaceStore
    let path: String?
    let name: String
    let isOwn: Bool
    @State private var loadedPath: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image, loadedPath == path {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 34, height: 34)
                    .background(MobileTheme.control)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            } else {
                AedrovaInitials(name: name, size: 34, emphasized: isOwn)
            }
        }
        .task(id: path) {
            if let path {
                let photo = await store.profilePhoto(path)
                guard !Task.isCancelled else { return }
                image = photo
                loadedPath = path
            } else {
                image = nil
                loadedPath = nil
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func trackChatEnd(_ onChange: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 24
            } action: { _, visible in
                onChange(visible)
            }
        } else {
            onPreferenceChange(ChatEndVisible.self, perform: onChange)
        }
    }

    @ViewBuilder
    func chatScrollAnchors(opensAtLatest: Bool) -> some View {
        if #available(iOS 18, *) {
            defaultScrollAnchor(opensAtLatest ? .bottom : .top, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            defaultScrollAnchor(.top)
        }
    }
}

private struct ChatEndVisible: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

enum Demo {
    static let user = UUID()
    static let teammate = UUID()
    static let designer = UUID()
    static let workspace = Workspace(id: UUID(), name: "Studio North")
    static let conversations = [
        Conversation(id: UUID(), name: "general", kind: "channel", dmLow: nil, dmHigh: nil, topic: "Team updates and decisions"),
        Conversation(id: UUID(), name: "launch", kind: "channel", dmLow: nil, dmHigh: nil, topic: "Release checklist and handoff"),
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
        if conversation.name == "launch" {
            return [
                .init(id: UUID(), author: "Jamie", body: "The release candidate is ready. I’ve added the install checks to the handoff.", createdAt: .now.addingTimeInterval(-420)),
                .init(id: UUID(), author: "Maya", body: "Mac smoke check passed. I’m taking the Windows install next.", createdAt: .now.addingTimeInterval(-240)),
                .init(id: UUID(), author: "Aedrova", body: "The remaining items are clean Windows install and download-link verification.", createdAt: .now.addingTimeInterval(-120), agent: true)
            ]
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
                    $0.id != user && !store.blockedPeople.contains($0.id)
                        && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query))
                }.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }) { person in
                    Button {
                        select(person)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AedrovaInitials(name: person.displayName)
                            Text(person.displayName).foregroundStyle(MobileTheme.ink)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .listRowBackground(MobileTheme.surface)
                    .listRowSeparatorTint(MobileTheme.line)
                }
            }
            .aedrovaPanelRows()
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
                        let scope = ChatScope(workspace: workspace.id, channel: conversation.id, parent: nil)
                        if let cached = store.cache.people(scope) {
                            members = cached
                            loading = false
                        }
                        let fresh = try await store.api.inventory(workspace: workspace.id,
                                                                   section: "people", channel: conversation.id).people
                        try Task.checkCancellation()
                        guard store.user == user else { return }
                        store.cache.storePeople(fresh, scope: scope)
                        members = fresh
                    }
                } catch is CancellationError {
                } catch {
                    if (error as? WorkspaceError)?.isAccessFailure == true {
                        store.cache.forget(workspace.id)
                        members = []
                    }
                    failure = message(for: error)
                }
            }
        }
    }
}
