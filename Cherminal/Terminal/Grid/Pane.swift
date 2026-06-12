import SwiftUI
import GhosttyKit

/// One pane in a workspace grid — a live Ghostty surface + its effective
/// conversation. Evolved from the old `TabSurfaceHolder` (same `surfaceView` +
/// `conversation` API, so existing call sites are unchanged) with the extra
/// identity a grid slot needs: a stable `id`, the opened `base` identity (for
/// shell↔agent adoption), grid position, optional role, lifecycle state.
@MainActor
final class Pane: ObservableObject, Identifiable {
    let id = UUID()

    /// nil = not yet spawned, or suspended to reclaim memory.
    @Published var surfaceView: Ghostty.SurfaceView?

    /// The effective conversation — starts as `base`, flips when the live-session
    /// linker detects a hand-launched agent. Views observe this.
    @Published var conversation: Conversation

    /// An agent PROCESS is running in this pane but no conversation could be
    /// linked yet — a brand-new chat that hasn't written its session file
    /// (claude writes nothing until the first message). The inspector shows
    /// a "new conversation" state instead of guessing an old one.
    @Published private(set) var pendingAgent: AgentKind?

    /// The identity the pane was opened with; adoption falls back to this.
    let base: Conversation

    @Published var role: PaneRole?
    @Published var lifecycleState: PaneLifecycle = .empty
    var gridPosition: GridPosition
    /// Last time this pane was focused/spawned — drives LRU suspension.
    var lastActiveAt = Date()
    /// Replaces the conversation-derived resume command at the FIRST spawn
    /// only (the background-attach path: `claude attach <id>`); consumed by
    /// spawnSurface. Respawns (a suspended pane resuming) go through the
    /// normal resume law instead — `dtach -A` on the same socket reattaches
    /// the live master anyway, and a stale attach against a session that has
    /// since ended would just fail.
    private(set) var spawnCommandOverride: String?

    /// One-shot read: returns the override and clears it.
    func consumeSpawnCommandOverride() -> String? {
        defer { spawnCommandOverride = nil }
        return spawnCommandOverride
    }

    init(conversation: Conversation,
         role: PaneRole? = nil,
         gridPosition: GridPosition = GridPosition(row: 0, col: 0),
         spawnCommandOverride: String? = nil) {
        self.base = conversation
        self.conversation = conversation
        self.role = role
        self.gridPosition = gridPosition
        self.spawnCommandOverride = spawnCommandOverride
        LiveCount.inc("pane")   // leak tripwire: → 0 when all panes close/suspend
    }

    deinit { LiveCount.dec("pane") }

    /// Adopt a detected live agent as the effective identity, or revert to base.
    /// `runningAgent` is the kind of agent process seen in the pane regardless
    /// of whether a conversation could be linked — a running agent WITHOUT a
    /// linkable conversation is a new chat (pendingAgent). Idempotent.
    /// (Window title is updated by the owning controller.)
    func applyDetectedSession(_ detected: Conversation?, runningAgent: AgentKind? = nil) {
        let pending = detected == nil ? runningAgent : nil
        if pendingAgent != pending { pendingAgent = pending }
        let target = detected ?? base
        guard conversation.id != target.id else { return }
        clog("tabs", "adopt id=\(target.id) agent=\(target.agent.rawValue) (was \(conversation.id))")
        conversation = target
    }
}

enum PaneLifecycle: Sendable {
    case empty       // no surface yet
    case spawning    // surface being created
    case live        // surface up
    case suspended   // surface released to reclaim memory; click to resume
}

/// The live runtime grid for one window: an ordered set of panes + their layout
/// + which one is active (the focus signal that replaces window-key). The
/// on-disk snapshot is `PersistedWorkspace`.
@MainActor
final class Workspace: ObservableObject {
    let id = UUID()
    @Published var panes: [Pane]
    @Published var layout: GridLayout
    @Published var activePaneID: Pane.ID?
    /// Full-window zoom: when set, that pane takes the whole grid area and the
    /// others hide (surfaces stay live at their grid sizes — no PTY reflow).
    /// Runtime-only: never persisted, a restored session comes back unzoomed.
    @Published var zoomedPaneID: Pane.ID?
    /// User-set tab name (double-click the tab / Tabs → Rename Tab). nil =
    /// automatic title (the active pane's room). Persisted with the workspace,
    /// so it survives relaunch and travels with saved Groups.
    @Published var name: String?

    init(panes: [Pane], layout: GridLayout = .single, name: String? = nil) {
        self.panes = panes
        self.layout = layout
        self.activePaneID = panes.first?.id
        self.name = name
    }

    var activePane: Pane? { panes.first { $0.id == activePaneID } ?? panes.first }

    func pane(id: Pane.ID) -> Pane? { panes.first { $0.id == id } }

    /// The focus law: activate a pane, and if the workspace is zoomed, the
    /// zoom follows the focus (jumping to a pane while zoomed shows THAT pane
    /// full-window — never a hidden pane holding the keyboard). Idempotent:
    /// publishes only on change (the click recognizer fires per drag-change).
    func focus(_ id: Pane.ID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        if activePaneID != id { activePaneID = id }
        if zoomedPaneID != nil, zoomedPaneID != id { zoomedPaneID = id }
    }

    /// Toggle full-window zoom on the active pane. A single-pane grid is
    /// already "zoomed" — no-op.
    func toggleZoom() {
        guard panes.count > 1, let target = activePaneID ?? panes.first?.id else {
            zoomedPaneID = nil
            return
        }
        zoomedPaneID = (zoomedPaneID == target) ? nil : target
    }

    /// Append a pane, re-fit the grid to the new count, and focus it.
    /// A new pane must be visible — unzoom.
    func addPane(_ pane: Pane) {
        panes.append(pane)
        layout = GridLayout.fit(panes.count)
        reindex()
        activePaneID = pane.id
        zoomedPaneID = nil
    }

    /// Remove a pane, re-fit, and move focus to the last remaining pane.
    /// Removing the zoomed pane unzooms (back to the grid); removing a hidden
    /// sibling keeps the zoom.
    func removePane(id: Pane.ID) {
        panes.removeAll { $0.id == id }
        layout = GridLayout.fit(max(1, panes.count))
        reindex()
        if activePaneID == id { activePaneID = panes.last?.id }
        if zoomedPaneID == id || panes.count < 2 { zoomedPaneID = nil }
    }

    /// Cycle the active pane by `delta` (wraps). While zoomed, the zoom
    /// follows — ⌘` cycles panes full-window.
    func focusNext(_ delta: Int = 1) {
        guard !panes.isEmpty else { return }
        defer { if zoomedPaneID != nil, let a = activePaneID { zoomedPaneID = a } }
        guard let cur = activePaneID, let i = panes.firstIndex(where: { $0.id == cur }) else {
            activePaneID = panes.first?.id
            return
        }
        let n = panes.count
        activePaneID = panes[((i + delta) % n + n) % n].id
    }

    private func reindex() {
        for (i, pane) in panes.enumerated() { pane.gridPosition = layout.position(for: i) }
    }
}
