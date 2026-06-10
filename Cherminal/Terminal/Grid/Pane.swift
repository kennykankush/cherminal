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

    /// The identity the pane was opened with; adoption falls back to this.
    let base: Conversation

    @Published var role: PaneRole?
    @Published var lifecycleState: PaneLifecycle = .empty
    var gridPosition: GridPosition
    /// Last time this pane was focused/spawned — drives LRU suspension.
    var lastActiveAt = Date()
    /// Replaces the conversation-derived resume command at spawn (the
    /// background-attach path: `claude attach <id>`). nil = normal spawn.
    let spawnCommandOverride: String?

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
    /// Idempotent. (Window title is updated by the owning controller.)
    func applyDetectedSession(_ detected: Conversation?) {
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

    /// Append a pane, re-fit the grid to the new count, and focus it.
    func addPane(_ pane: Pane) {
        panes.append(pane)
        layout = GridLayout.fit(panes.count)
        reindex()
        activePaneID = pane.id
    }

    /// Remove a pane, re-fit, and move focus to the last remaining pane.
    func removePane(id: Pane.ID) {
        panes.removeAll { $0.id == id }
        layout = GridLayout.fit(max(1, panes.count))
        reindex()
        if activePaneID == id { activePaneID = panes.last?.id }
    }

    /// Cycle the active pane by `delta` (wraps).
    func focusNext(_ delta: Int = 1) {
        guard !panes.isEmpty else { return }
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
