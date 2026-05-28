import SwiftUI

/// Central design tokens for Cherminal. Every spacing, type ramp, and
/// surface-color choice across the app references this file so the
/// aesthetic stays consistent and is changeable in one place.
///
/// The vibe: macOS 26 Liquid Glass premium — Tahoe-native chrome,
/// restrained color, generous spacing, monospace where the content is
/// terminal-adjacent, refined system font everywhere else.
enum CHM {

    // MARK: - Spacing

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner radius

    enum Radius {
        static let chip: CGFloat = 6
        static let tab: CGFloat = 8
        static let card: CGFloat = 12
        static let modal: CGFloat = 16
    }

    // MARK: - Typography

    /// Use `CHM.Font.*` instead of raw `.system(...)` everywhere. The size
    /// scale is tuned for a dense pro tool on retina: small caps for
    /// metadata, body at 13pt, monospace shrinks to 12pt to match.
    enum Font {
        // Display / section labels (uppercased small caps)
        static let eyebrow: SwiftUI.Font = .system(size: 10, weight: .semibold, design: .default)
        // Sidebar app title etc.
        static let brand: SwiftUI.Font = .system(size: 13, weight: .semibold, design: .default)
        // Conversation titles, tab labels
        static let bodyEmphasis: SwiftUI.Font = .system(size: 13, weight: .medium, design: .default)
        static let body: SwiftUI.Font = .system(size: 13, weight: .regular, design: .default)
        // Secondary row info (timestamps, room names)
        static let caption: SwiftUI.Font = .system(size: 11, weight: .regular, design: .default)
        static let captionEmphasis: SwiftUI.Font = .system(size: 11, weight: .medium, design: .default)
        // Paths, IDs, anything terminal-adjacent
        static let mono: SwiftUI.Font = .system(size: 12, weight: .regular, design: .monospaced)
        static let monoSmall: SwiftUI.Font = .system(size: 11, weight: .regular, design: .monospaced)
    }

    // MARK: - Color tokens

    /// Cherminal's accent — warm clay-orange. Pulled from the Claude
    /// agent badge so the brand identity threads through. Used very
    /// sparingly: selection rings, save buttons, brand mark.
    enum Color {
        static let accent = SwiftUI.Color(red: 0.91, green: 0.52, blue: 0.28)
        static let accentMuted = SwiftUI.Color(red: 0.91, green: 0.52, blue: 0.28).opacity(0.18)

        // Subtle dividers, hairlines, low-emphasis fills
        static let hairline = SwiftUI.Color.primary.opacity(0.10)
        static let hoverFill = SwiftUI.Color.primary.opacity(0.06)
        static let activeFill = SwiftUI.Color.primary.opacity(0.10)

        // Terminal background — matches what TabsBar's active tab blends into
        static let terminalBackground = SwiftUI.Color.black
    }

    // MARK: - Heights

    /// Standard heights for the horizontal chrome strips. Multiples of 4.
    enum BarHeight {
        static let bookmarks: CGFloat = 32
        static let tabs: CGFloat = 36
        static let sidebarHeader: CGFloat = 52
    }

    // MARK: - Motion

    /// Centralized animation curves so everything moves on the same beat.
    enum Motion {
        static let hover: Animation = .easeOut(duration: 0.12)
        static let tabSwitch: Animation = .spring(response: 0.28, dampingFraction: 0.85)
        static let appear: Animation = .easeOut(duration: 0.18)
    }
}
