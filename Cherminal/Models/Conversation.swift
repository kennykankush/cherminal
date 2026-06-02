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

    /// Single-glyph mark used in the sidebar chip. SF Symbol names chosen
    /// to be evocative of each agent's visual identity without literally
    /// reproducing the brand's official mark.
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

/// Small circular chip rendered next to every conversation row and in the
/// terminal header. Designed to be glanceable at 18pt.
struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(agent.tint.opacity(0.16))
            Image(systemName: agent.markSymbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(agent.tint)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(agent.displayName))
    }
}

enum ConversationState: Hashable, Sendable {
    case live
    case idle
    case dormant
    case pinned
}

struct Conversation: Identifiable, Hashable, Sendable {
    let id: String
    let agent: AgentKind
    let roomPath: URL
    let sessionFile: URL
    let firstMessageAt: Date?
    let lastActivityAt: Date
    let messageCount: Int
    let previewText: String?
    let state: ConversationState
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
