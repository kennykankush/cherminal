import Foundation

extension Conversation {
    /// Build a synthetic "shell" conversation — what fresh-shell tabs use
    /// to flow through the same Conversation-keyed pipeline (window state,
    /// persistence, badges, surface configs) without needing a real
    /// session file on disk. Each call returns a unique id so multiple
    /// shells don't collapse into one.
    static func shellConversation(cwd: URL) -> Conversation {
        Conversation(
            id: UUID().uuidString,
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
