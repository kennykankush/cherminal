import Foundation
import SwiftUI

// MARK: - Grid geometry

/// A pane grid's dimensions. Pure value type; the renderer (TerminalGridView)
/// interprets it. `fit` picks a near-square layout for N panes (1→1×1, 2→1×2,
/// 3–4→2×2, …, ≤16→4×4).
struct GridLayout: Codable, Hashable, Sendable {
    var rows: Int
    var cols: Int

    var capacity: Int { rows * cols }

    static let single = GridLayout(rows: 1, cols: 1)

    static func fit(_ count: Int) -> GridLayout {
        let n = max(1, count)
        switch n {
        case 1:      return GridLayout(rows: 1, cols: 1)
        case 2:      return GridLayout(rows: 1, cols: 2)
        case 3...4:  return GridLayout(rows: 2, cols: 2)
        case 5...6:  return GridLayout(rows: 2, cols: 3)
        case 7...9:  return GridLayout(rows: 3, cols: 3)
        case 10...12: return GridLayout(rows: 3, cols: 4)
        default:     return GridLayout(rows: 4, cols: 4)   // ≤16
        }
    }

    /// Row/col of the Nth pane in reading order.
    func position(for index: Int) -> GridPosition {
        let c = max(1, cols)
        return GridPosition(row: index / c, col: index % c)
    }
}

/// A pane's slot in the grid. Spans default to 1 (equal cells in v1); kept in
/// the model so a future drag-to-resize doesn't force a migration.
struct GridPosition: Codable, Hashable, Sendable {
    var row: Int
    var col: Int
    var rowSpan: Int = 1
    var colSpan: Int = 1
}

// MARK: - Roles (labels/metadata only — no orchestration)

/// A swarm role is a label + an optional tint. Free-text name (users can invent
/// roles); built-in presets just seed common ones. Tint reuses the AgentBadge
/// recipe (tint at 0.16 fill).
struct PaneRole: Codable, Hashable, Sendable {
    var name: String
    var tint: RoleTint?

    static let builder  = PaneRole(name: "Builder",  tint: .green)
    static let reviewer = PaneRole(name: "Reviewer", tint: .purple)
    static let scout    = PaneRole(name: "Scout",    tint: .blue)
    static let presets: [PaneRole] = [.builder, .reviewer, .scout]
}

/// A small fixed palette so roles are Codable-stable and visually scannable.
enum RoleTint: String, Codable, Hashable, Sendable, CaseIterable {
    case green, purple, blue, orange, pink, neutral

    var color: Color {
        switch self {
        case .green:   Color(red: 0.36, green: 0.72, blue: 0.45)
        case .purple:  Color(red: 0.58, green: 0.45, blue: 0.85)
        case .blue:    Color(red: 0.36, green: 0.60, blue: 0.90)
        case .orange:  Color(red: 0.91, green: 0.58, blue: 0.30)
        case .pink:    Color(red: 0.90, green: 0.42, blue: 0.62)
        case .neutral: Color.secondary
        }
    }
}

// MARK: - Persisted workspace (a saved grid)

/// One slot in a saved grid — the grid analog of `PersistedTab`. Same
/// agent/shell fallback rules: `agentRaw == AgentKind.shell.rawValue` means a
/// synthetic shell at `roomPath`, otherwise resume the agent session.
struct PersistedPane: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    let conversationID: String
    let agentRaw: String
    let roomPath: String
    var role: PaneRole?
    var gridPosition: GridPosition
}

/// A saved grid: ordered panes + their layout. Supersedes the loose
/// `[PersistedTab]` lastSession blob for the ADE model (the *active* workspace
/// is persisted to UserDefaults; the saved library lives in SessionCache).
struct Workspace: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var layout: GridLayout
    var panes: [PersistedPane]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         layout: GridLayout = .single,
         panes: [PersistedPane] = [],
         createdAt: Date = .now,
         updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.layout = layout
        self.panes = panes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Swarm templates (a launchable set of role+agent specs)

/// One agent to launch into a grid slot. A template's specs map 1:1 to panes.
/// `initialPrompt` is injected into the spawned surface (the only "agentic"
/// bit) — no inter-agent messaging.
struct SwarmRoleSpec: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var role: PaneRole
    var agent: AgentKind
    var cwd: String?            // nil = inherit launch-time active room
    var initialPrompt: String?
    var gridPosition: GridPosition
}

/// A reusable, named recipe that opens N role-tagged panes into a grid. Not a
/// Workspace: a template is a spec; launching it *produces* concrete panes.
struct SwarmTemplate: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var layout: GridLayout
    var specs: [SwarmRoleSpec]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         layout: GridLayout = .single,
         specs: [SwarmRoleSpec] = [],
         createdAt: Date = .now,
         updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.layout = layout
        self.specs = specs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
