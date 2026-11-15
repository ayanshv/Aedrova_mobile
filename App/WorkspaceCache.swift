import Foundation

struct ChatScope: Hashable {
    let workspace: UUID
    let channel: UUID
    let parent: UUID?
}

struct ChatSnapshot {
    static let pageSize = 60

    let messages: [Message]
    let replies: [AgentReply]
    let checkedAt: ContinuousClock.Instant

    var cursor: Int64? { messages.map(\.sequence).max() }

    func merging(_ changes: [Message]) -> [Message] {
        var merged = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for message in changes { merged[message.id] = message }
        return Array(merged.values.sorted { $0.sequence > $1.sequence }.prefix(Self.pageSize))
    }
}

@MainActor
final class WorkspaceCache {
    private struct Entry<Value> {
        let value: Value
        let expires: ContinuousClock.Instant
    }

    private let clock = ContinuousClock()
    private var directories: [UUID: Entry<[Conversation]>] = [:]
    private var chats: [ChatScope: Entry<ChatSnapshot>] = [:]
    private var mentions: [ChatScope: Entry<[ChatInventory.Member]>] = [:]

    func conversations(_ workspace: UUID) -> [Conversation]? { fresh(directories[workspace]) }

    func storeConversations(_ value: [Conversation], workspace: UUID) {
        insert(value, for: workspace, into: &directories)
        let allowed = Set(value.map(\.id))
        chats = chats.filter { $0.key.workspace != workspace || allowed.contains($0.key.channel) }
        mentions = mentions.filter { $0.key.workspace != workspace || allowed.contains($0.key.channel) }
    }

    func chat(_ scope: ChatScope) -> ChatSnapshot? { fresh(chats[scope]) }
    func storeChat(_ value: ChatSnapshot, scope: ChatScope) { insert(value, for: scope, into: &chats) }

    func people(_ scope: ChatScope) -> [ChatInventory.Member]? { fresh(mentions[scope]) }
    func storePeople(_ value: [ChatInventory.Member], scope: ChatScope) {
        insert(value, for: scope, into: &mentions)
    }

    func forget(_ workspace: UUID) {
        directories[workspace] = nil
        chats = chats.filter { $0.key.workspace != workspace }
        mentions = mentions.filter { $0.key.workspace != workspace }
    }

    func search(_ query: String, workspace: UUID) -> [ChatInventory.Entry] {
        chats.filter { $0.key.workspace == workspace && $0.value.expires > clock.now }
            .flatMap { scope, entry in
                entry.value.messages.filter {
                    $0.unsentAt == nil && $0.body.localizedCaseInsensitiveContains(query)
                }.map { (scope, $0) }
            }
            .sorted { $0.1.sequence > $1.1.sequence }
            .prefix(30)
            .map { scope, row in
                .init(id: row.id, channelId: scope.channel, parentId: scope.parent,
                      sequence: row.sequence, body: row.body, notification: nil, seenAt: nil)
            }
    }

    private func fresh<Value>(_ entry: Entry<Value>?) -> Value? {
        guard let entry, entry.expires > clock.now else { return nil }
        return entry.value
    }

    private func insert<Key: Hashable, Value>(_ value: Value, for key: Key, into entries: inout [Key: Entry<Value>]) {
        let now = clock.now
        entries = entries.filter { $0.value.expires > now }
        if entries[key] == nil, entries.count >= 24,
           let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(value: value, expires: now.advanced(by: .seconds(20)))
    }
}
