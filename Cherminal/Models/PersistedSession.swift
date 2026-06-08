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
    /// When this was parked in the tray — persisted so the shell age-reap policy
    /// survives quit/relaunch (a shell parked days ago must still be reaped, not
    /// treated as freshly parked). Only the detached-tray encoding sets it; the
    /// session/bookmark encodings leave it nil. Optional so older data decodes.
    var detachedAt: Date? = nil
}

/// One slot in a saved grid — the grid analog of `PersistedTab`. Same
/// agent/shell fallback rules: `agentRaw == AgentKind.shell.rawValue` means a
/// synthetic shell reopened at `roomPath`, otherwise the agent session resumes.
struct PersistedPane: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    let conversationID: String
    let agentRaw: String
    let roomPath: String
    var role: PaneRole?
    var gridPosition: GridPosition
    /// Reserved for the dtach-all phase: the stable dtach socket key (= the
    /// conversation id for agents today). Optional so older saved data decodes.
    var socketID: String?
}

/// A saved tab's full grid: ordered panes + their layout. Supersedes the
/// single-active-pane `[PersistedTab]` lastSession blob — restoring rebuilds the
/// whole arrangement, not just the focused pane. `Persisted*` = on-disk
/// snapshot; the live runtime grid is the `Workspace` ObservableObject.
struct PersistedWorkspace: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var layout: GridLayout
    var panes: [PersistedPane]
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
