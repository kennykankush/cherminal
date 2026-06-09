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
    /// session encoding leaves it nil. Optional so older data decodes.
    var detachedAt: Date? = nil
}

/// One slot in a saved grid — the grid analog of `PersistedTab`. Same
/// agent/shell fallback rules: `agentRaw == AgentKind.shell.rawValue` means a
/// synthetic shell reopened at `roomPath`, otherwise the agent session resumes.
/// Deliberately minimal: geometry (layout / grid position) is fully derivable
/// from pane COUNT + ORDER on restore (`GridLayout.fit` + reindex), so it isn't
/// persisted — a field that restore ignores is where silent drift breeds.
/// (Older snapshots carry extra keys — layout, gridPosition, id — which decode
/// ignores.)
struct PersistedPane: Codable, Hashable, Sendable {
    let conversationID: String
    let agentRaw: String
    let roomPath: String
    var role: PaneRole?
    /// The pane's dtach socket key when it DIFFERS from `conversationID`: a
    /// hand-launched agent adopted inside a wrapped shell keeps the SHELL's
    /// socket (sockets are fixed at spawn), so its live master is keyed on the
    /// shell id while the pane's identity is the agent's. Persisting the real
    /// socket lets the launch sweep keep that master alive and lets restore
    /// REATTACH it (the agent is still running inside) instead of cold-
    /// resuming — see ConversationLedger.restorePlan. nil when the socket is
    /// just the conversation id (sidebar-opened agents, plain shells).
    var socketID: String? = nil
}

/// A saved tab's full grid: ordered panes + the user's tab name (if set).
/// Supersedes the single-active-pane `[PersistedTab]` lastSession blob —
/// restoring rebuilds the whole arrangement, not just the focused pane.
/// `Persisted*` = on-disk snapshot; the live runtime grid is the `Workspace`
/// ObservableObject.
struct PersistedWorkspace: Codable, Hashable, Sendable {
    /// User-set tab name; nil = automatic title. Optional so older snapshots decode.
    var name: String? = nil
    var panes: [PersistedPane]
}

/// A user-named bundle of saved tab grids ("Groups"). Since 2026-06: stores
/// FULL workspaces — every pane of every tab — so "Save this workspace" means
/// exactly that; legacy single-pane-per-tab bookmarks migrate on decode (see
/// SessionCache.loadBookmarks).
struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var workspaces: [PersistedWorkspace]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, workspaces: [PersistedWorkspace], createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.workspaces = workspaces
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
