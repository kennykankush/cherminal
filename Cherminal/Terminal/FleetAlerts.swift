import AppKit
import UserNotifications

/// Fleet awareness when you're not watching the grid: a macOS notification the
/// moment an agent finishes a turn (in a tab/pane you're not looking at), plus a
/// Dock badge counting how many agents are waiting on you. Pure external signal —
/// driven by the coordinator's `awaitingTurnIDs` (read from session files, no
/// hooks). Tapping a notification jumps straight to that pane.
@MainActor
enum FleetAlerts {
    /// Ask once for notification permission (no-op on later launches — the system
    /// remembers the choice). The Dock badge works regardless of this.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a "your turn" notification for a freshly-finished agent. The id is
    /// stable per conversation, so a later turn replaces (not stacks) the banner.
    static func notifyDone(_ conversation: Conversation) {
        let content = UNMutableNotificationContent()
        content.title = "\(conversation.agent.displayName) · \(conversation.roomName)"
        content.body = "Finished — your turn"
        content.sound = .default
        content.userInfo = ["conversationID": conversation.id]
        let req = UNNotificationRequest(identifier: id(for: conversation.id), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Drop a delivered notification once you've looked at that pane.
    static func clearDelivered(conversationID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id(for: conversationID)])
    }

    /// Reflect the count of agents waiting on you in the Dock badge (nil = clear).
    static func updateBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private static func id(for conversationID: String) -> String { "chm.done.\(conversationID)" }
}

/// Detects a "burst" — an agent that has hit its account usage/plan limit and is
/// stuck until it resets. The limit banner shows in the terminal (codex doesn't
/// log it), so we match against the pane's VISIBLE text (what you see). The
/// markers are deliberately distinctive CLI phrasings so a chat that merely
/// *mentions* usage limits doesn't trip them. A burst is account-wide, so one
/// detected pane flags the whole agent type (see TabWindowCoordinator).
enum BurstDetector {
    /// Short red-banner label for an agent ("CODEX" / "CLAUDE").
    static func label(for agent: AgentKind) -> String {
        switch agent {
        case .codex:      return "CODEX"
        case .claudeCode: return "CLAUDE"
        default:          return agent.rawValue.uppercased()
        }
    }

    /// Claude Code's banner family, extracted from the installed binary
    /// (2026-06-10): the composer is literally
    /// `function h9H(H,_){return`You've hit your ${H}${_}`}` with H ∈
    /// {"session limit","weekly limit","Opus limit","Sonnet limit"}, plus a
    /// "usage limit reached — check plan" status-line variant. The
    /// "You're close to your usage limit" APPROACHING warning must not trip.
    /// Both straight and curly apostrophes, since terminals render either.
    private static let claudeBurstMarkers: [String] = {
        var out: [String] = ["usage limit reached — check plan"]
        for apostrophe in ["'", "\u{2019}"] {
            for label in ["session limit", "weekly limit", "opus limit",
                          "sonnet limit", "usage limit"] {
                out.append("you\(apostrophe)ve hit your \(label)")
            }
        }
        return out
    }()

    static func isBursting(agent: AgentKind, visibleText: String) -> Bool {
        let t = visibleText.lowercased()
        switch agent {
        case .codex:
            // "You've hit your usage limit. Visit …/usage to purchase more
            // credits or try again at <date>." — distinctive enough to be safe.
            return t.contains("hit your usage limit")
        case .claudeCode:
            return claudeBurstMarkers.contains { t.contains($0) }
        default:
            return false
        }
    }
}
