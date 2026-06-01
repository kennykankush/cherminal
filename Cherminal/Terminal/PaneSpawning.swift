import Foundation

/// The seam between the ADE feature managers (workspace / swarm / kanban) and
/// whatever actually renders & spawns terminal panes. Managers depend only on
/// this protocol, so kanban + swarm + workspace persistence can be built and
/// shipped before the multi-surface grid rewrite lands. `TabWindowCoordinator`
/// conforms to it — first in its current tab-era form (1×N "slots"), then with
/// the real grid.
@MainActor
protocol PaneSpawning: AnyObject {
    /// Replace the active grid with `workspace`: clear current panes, then spawn
    /// a surface for each persisted pane at its position.
    func loadWorkspace(_ workspace: Workspace)

    /// Spawn one surface for `conversation` at `position`, tagged with `role`.
    /// Returns the new pane's id. Mirrors the existing deferred-spawn path.
    @discardableResult
    func spawnPane(_ conversation: Conversation, role: PaneRole?, at position: GridPosition) -> UUID

    /// Inject text into a pane's surface (used for SwarmRoleSpec.initialPrompt).
    /// No-op if the pane has no live surface.
    func sendText(_ text: String, toPaneID id: UUID)

    /// Snapshot the current grid for persistence.
    func currentPanes() -> [PersistedPane]

    /// The current grid layout.
    var currentLayout: GridLayout { get }
}
