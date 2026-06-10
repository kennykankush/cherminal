import Foundation
import SwiftUI

enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case claudeCode
    case codex
    /// Bare shell tab — no agent attached. Represented as a synthetic
    /// Conversation so it flows through the same tab/persistence pipeline
    /// as agent sessions.
    case shell
    case unknown

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .shell: "Terminal"
        case .unknown: "Agent"
        }
    }

    /// Asset-catalog name of the agent's REAL brand mark (lobe-icons dark
    /// variants, vendored into Assets.xcassets); nil falls back to the SF
    /// Symbol below. Real marks make the sidebar scannable the way the
    /// Claude/ChatGPT desktop sidebars are.
    var markImageName: String? {
        switch self {
        case .claudeCode: "AgentMark-ClaudeCode"
        case .codex: "AgentMark-Codex"
        case .shell, .unknown: nil
        }
    }

    /// SF Symbol fallback for kinds without a brand mark.
    var markSymbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "cube.transparent.fill"
        case .shell: "terminal.fill"
        case .unknown: "circle.dashed"
        }
    }

    /// Brand-ish tint. Claude leans warm orange; Codex + shell stay neutral
    /// so the two AI agents are easy to scan among bare-terminal tabs.
    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.91, green: 0.52, blue: 0.28)
        case .codex: Color.primary
        case .shell: Color.secondary
        case .unknown: Color.secondary
        }
    }
}

/// The agent's mark, rendered next to every conversation row and in the
/// terminal header. Claude Code and Codex show their REAL logos, bare (no
/// chip) — the way the Claude/ChatGPT desktop sidebars present icons; kinds
/// without a brand mark keep the subtle circled SF Symbol. Glanceable at 18pt.
struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let name = agent.markImageName {
                Image(name)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle()
                        .fill(agent.tint.opacity(0.16))
                    Image(systemName: agent.markSymbol)
                        .font(.system(size: size * 0.55, weight: .semibold))
                        .foregroundStyle(agent.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(agent.displayName))
    }
}

struct Conversation: Identifiable, Hashable, Sendable {
    let id: String
    let agent: AgentKind
    let roomPath: URL
    let sessionFile: URL
    let firstMessageAt: Date?
    let lastActivityAt: Date
    let previewText: String?
    // NOTE deliberately absent: a `state` enum (live/idle/dormant/pinned) and a
    // `messageCount` both used to ride along here and were trusted by nothing —
    // liveness comes from the coordinator's reconcile, pins from PinsManager,
    // and the head+tail parse can't count messages truthfully (Deep mode ranks
    // by file size; the inspector shows the accumulator's exact count). A model
    // field nobody believes is bank-logic rot, so they're gone.
    /// If this session is a post-compaction continuation, the id of the session
    /// it continues from (Claude writes the parent's path + a "Continue the
    /// conversation…" handoff into the new session's first user turn). Lets the
    /// sidebar mark the superseded parent so a compaction never reads as a
    /// mysterious duplicate. `var` with a default so call sites that don't know
    /// about it (shell conversations, etc.) compile unchanged.
    var continuedFromID: String? = nil

    var roomName: String { roomPath.lastPathComponent }
}

struct Room: Identifiable, Hashable, Sendable {
    let id: String
    let path: URL
    var conversations: [Conversation]

    var name: String { path.lastPathComponent }
    var lastActivityAt: Date {
        conversations.map(\.lastActivityAt).max() ?? .distantPast
    }
}
