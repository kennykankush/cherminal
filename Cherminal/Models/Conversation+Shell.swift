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
            previewText: nil
        )
    }

    /// Reconstruct an agent conversation from persisted restore data when the
    /// registry hasn't loaded it yet (cache miss / brand-new session). Enough to
    /// RESUME by id — TerminalCommand builds the resume command from id + agent —
    /// so the agent reattaches its live `dtach` master instead of being lost to a
    /// blank shell. `sessionFile` is best-effort (the accurate one arrives with
    /// the registry's next scan); for Claude it's derivable from the room slug.
    static func restoredAgent(id: String, agent: AgentKind, room: URL) -> Conversation {
        let sessionFile: URL = {
            guard agent == .claudeCode else { return room }  // codex rollout path isn't derivable
            // Claude stores <id>.jsonl under ~/.claude/projects/<slug>/, the slug
            // being the absolute room path with separators turned to dashes.
            let slug = "-" + room.path.dropFirst()
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects/\(slug)/\(id).jsonl")
        }()
        return Conversation(
            id: id,
            agent: agent,
            roomPath: room,
            sessionFile: sessionFile,
            firstMessageAt: nil,
            lastActivityAt: .now,
            previewText: nil
        )
    }
}
