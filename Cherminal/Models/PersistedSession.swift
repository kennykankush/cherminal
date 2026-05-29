import Foundation

/// Snapshot of one tab as written to disk. Cherminal never persists the
/// live PTY — restoring means re-spawning the agent with `claude --resume`
/// or `codex resume`, which works because the agents themselves own the
/// conversation state on disk.
struct PersistedTab: Codable, Hashable, Sendable, Identifiable {
    var id: String { conversationID }
    let conversationID: String
    let agentRaw: String
    let roomPath: String
}

/// A user-named bundle of tabs the user explicitly bookmarked. Chrome's
/// tab-group / saved-tabs pattern.
struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var tabs: [PersistedTab]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, tabs: [PersistedTab], createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
