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
