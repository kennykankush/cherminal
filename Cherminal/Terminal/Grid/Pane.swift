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

    init(conversation: Conversation,
         role: PaneRole? = nil,
         gridPosition: GridPosition = GridPosition(row: 0, col: 0)) {
        self.base = conversation
        self.conversation = conversation
        self.role = role
        self.gridPosition = gridPosition
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

    init(panes: [Pane], layout: GridLayout = .single) {
        self.panes = panes
        self.layout = layout
        self.activePaneID = panes.first?.id
    }

    var activePane: Pane? { panes.first { $0.id == activePaneID } ?? panes.first }

    func pane(id: Pane.ID) -> Pane? { panes.first { $0.id == id } }
}
