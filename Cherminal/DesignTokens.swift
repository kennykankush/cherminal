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
        // The single big number — the context-window percentage.
        static let metric: SwiftUI.Font = .system(size: 24, weight: .semibold, design: .rounded)
    }

    // MARK: - Icon sizes

    enum Icon {
        /// Empty-state / placeholder glyph — one size everywhere.
        static let emptyState: CGFloat = 32
    }

    // MARK: - Color tokens

    /// Cherminal's accent — warm clay-orange. Pulled from the Claude
    /// agent badge so the brand identity threads through. Used very
    /// sparingly: selection rings, save buttons, brand mark.
    enum Color {
        static let accent = SwiftUI.Color(red: 0.91, green: 0.52, blue: 0.28)

        // Subtle dividers, hairlines, low-emphasis fills
        static let hairline = SwiftUI.Color.primary.opacity(0.10)
        static let hoverFill = SwiftUI.Color.primary.opacity(0.06)
        static let activeFill = SwiftUI.Color.primary.opacity(0.10)
        static let fillSubtle = SwiftUI.Color.primary.opacity(0.04)

        /// Calm "your turn" signal — cool blue, low-arousal (never the alarm red).
        static let attention = SwiftUI.Color(red: 0.40, green: 0.62, blue: 0.92)
        static let attentionHalo = SwiftUI.Color(red: 0.40, green: 0.62, blue: 0.92).opacity(0.25)
        /// Earned, desaturated warning — only at the very top of the gauge.
        static let alert = SwiftUI.Color(red: 0.80, green: 0.42, blue: 0.40)
    }

    // MARK: - Motion

    /// Centralized animation curves so everything moves on the same beat.
    enum Motion {
        static let hover: Animation = .easeOut(duration: 0.12)
        static let tabSwitch: Animation = .spring(response: 0.28, dampingFraction: 0.85)
        static let appear: Animation = .easeOut(duration: 0.18)
        /// Sidebar mode-swap CONTENT push (By room ⇄ Recent). ease-out-quart:
        /// snappy start, calm landing — no overshoot, so the heavy List slide
        /// doesn't wobble.
        static let modeSwitch: Animation = .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.2)
        /// The toggle THUMB slide. A spring with a touch of overshoot — the
        /// SwiftUI equivalent of the EPL⟷CUP pill's cubic-bezier(.34,1.2,.64,1):
        /// it pops just past the destination edge before settling. The "pop" is
        /// what makes the toggle feel alive rather than mechanical.
        static let pillSlide: Animation = .spring(response: 0.3, dampingFraction: 0.64)
        /// Slow, autoreversing "alive" pulse for the attention light — sub-blink,
        /// never an alert. Honor Reduce Motion at call sites.
        /// PREFER `CHM.Phase` + TimelineView for ambient/looping indicators:
        /// repeatForever animations restart whenever a re-render touches their
        /// view (the minimap glitch), while wall-clock phases can't.
        static let breathe: Animation = .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
    }

    /// Deterministic wall-clock phases for ambient looping motion (breathing
    /// lights, sweeps). Drive these from a `TimelineView` — the phase derives
    /// from the clock, so view re-renders can never reset, jump, or desync the
    /// animation the way `@State` + `repeatForever` does.
    enum Phase {
        /// 0→1 sawtooth over `period` seconds (linear time, for sweeps — time
        /// should feel linear; easing makes progress feel inconsistent).
        static func ramp(_ date: Date, period: Double) -> Double {
            let t = date.timeIntervalSinceReferenceDate
            return (t.truncatingRemainder(dividingBy: period)) / period
        }
        /// Smooth 0→1→0 sine over `period` seconds (for breathing opacity).
        static func breathe(_ date: Date, period: Double) -> Double {
            0.5 + 0.5 * sin(ramp(date, period: period) * 2 * .pi)
        }
    }
}
