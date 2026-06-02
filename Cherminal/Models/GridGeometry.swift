import SwiftUI

/// A pane grid's dimensions. `fit` picks a near-square layout for N panes
/// (1→1×1, 2→1×2, 3–4→2×2, …, ≤16→4×4).
struct GridLayout: Codable, Hashable, Sendable {
    var rows: Int
    var cols: Int

    var capacity: Int { rows * cols }
    static let single = GridLayout(rows: 1, cols: 1)

    static func fit(_ count: Int) -> GridLayout {
        switch max(1, count) {
        case 1:       return GridLayout(rows: 1, cols: 1)
        case 2:       return GridLayout(rows: 1, cols: 2)
        case 3...4:   return GridLayout(rows: 2, cols: 2)
        case 5...6:   return GridLayout(rows: 2, cols: 3)
        case 7...9:   return GridLayout(rows: 3, cols: 3)
        case 10...12: return GridLayout(rows: 3, cols: 4)
        default:      return GridLayout(rows: 4, cols: 4)   // ≤16
        }
    }

    func position(for index: Int) -> GridPosition {
        let c = max(1, cols)
        return GridPosition(row: index / c, col: index % c)
    }
}

/// A pane's slot in the grid (spans reserved for a future drag-to-resize).
struct GridPosition: Codable, Hashable, Sendable {
    var row: Int
    var col: Int
    var rowSpan: Int = 1
    var colSpan: Int = 1
}

/// Optional pane label + tint. Manual splits leave it nil; reserved so a future
/// "role" feature can tag panes without touching the grid code.
struct PaneRole: Codable, Hashable, Sendable {
    var name: String
    var tint: RoleTint?
}

enum RoleTint: String, Codable, Hashable, Sendable {
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
