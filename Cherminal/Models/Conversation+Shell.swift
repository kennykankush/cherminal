import Foundation

extension Conversation {
    /// Build a synthetic "shell" conversation — what fresh-shell tabs use
    /// to flow through the same Conversation-keyed pipeline (window state,
    /// persistence, badges, surface configs) without needing a real
    /// session file on disk. A fresh shell gets a unique id so multiple shells
    /// don't collapse; reopening a *saved* shell passes its persisted id so the
    /// tab dedups (reopening the same group focuses it instead of duplicating).
    static func shellConversation(cwd: URL, id: String = UUID().uuidString) -> Conversation {
        Conversation(
            id: id,
            agent: .shell,
            roomPath: cwd,
            sessionFile: cwd,
            firstMessageAt: nil,
            lastActivityAt: .now,
            messageCount: 0,
            previewText: nil,
            state: .live
        )
    }
}
