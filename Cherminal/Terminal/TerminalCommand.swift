import Foundation
import GhosttyKit

/// Builds the Ghostty surface command + config for a given conversation.
/// One place — sidebar, bookmarks, and window restore all funnel through
/// `surfaceConfig(for:)` so the spawned process gets identical setup
/// regardless of where the open request originated.
///
/// Uses the same permission-bypass flags as the user's shell aliases
/// (`codecode`, `gptgpt`) so resumed sessions don't prompt for tool
/// permission inside Cherminal. Aliases themselves can't be used here —
/// Ghostty spawns the command directly, not through an interactive shell
/// that would source `~/.zshrc`. We deliberately drop cmux-style
/// `--enable hooks` to honor the vision's "observe externally, never
/// inject" rule.
enum TerminalCommand {
    // NOTE: agents are wrapped in `dtach` and deliberately DON'T drop to a
    // fallback shell when they exit. With `dtach`, a `; exec $SHELL` tail left
    // the master alive as a bare shell after the agent quit — so reopening the
    // conversation reattached that zombie shell instead of resuming the agent
    // ("doesn't go to the convo"). Without the tail, a finished agent's master
    // exits, the socket frees, and reopening re-runs `--resume` and lands back
    // in the conversation. (Trade: a brief "Process exited" instead of a shell.)

    static func resume(for conversation: Conversation) -> String? {
        switch conversation.agent {
        case .claudeCode:
            guard let id = safeSessionID(conversation.id) else { return nil }
            let bin = BinaryResolver.shared.path(for: "claude")
            return Dtach.wrap("\(bin) --dangerously-skip-permissions --resume \(id)", id: id)
        case .codex:
            guard let id = safeSessionID(conversation.id) else { return nil }
            let bin = BinaryResolver.shared.path(for: "codex")
            return Dtach.wrap("\(bin) --dangerously-bypass-approvals-and-sandbox resume \(id)", id: id)
        case .shell, .unknown:
            // No command override → Ghostty spawns the user's default shell
            // in `cfg.workingDirectory`.
            return nil
        }
    }

    /// Session IDs are agent-issued UUIDs that we interpolate into a shell
    /// command string. Reject anything outside the UUID alphabet so a malformed
    /// id can never inject shell metacharacters; nil falls back to a bare shell.
    private static let idAllowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    private static func safeSessionID(_ id: String) -> String? {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(idAllowed.contains) else {
            clog("tabs", "refusing to resume — unsafe session id \(id)")
            return nil
        }
        return id
    }

    static func surfaceConfig(for conversation: Conversation) -> Ghostty.SurfaceConfiguration {
        var cfg = Ghostty.SurfaceConfiguration()

        // Guard against stale conversations whose room folder has since been
        // deleted: spawning a Ghostty surface with a non-existent
        // workingDirectory can fault in the C layer. Fall back to $HOME.
        let roomPath = conversation.roomPath.path
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: roomPath, isDirectory: &isDir) && isDir.boolValue
        if exists {
            cfg.workingDirectory = roomPath
        } else {
            cfg.workingDirectory = NSHomeDirectory()
            clog("tabs", "stale room — \(roomPath) missing; cwd → $HOME")
        }

        cfg.command = resume(for: conversation)
        cfg.environmentVariables = BinaryResolver.shared.environment()
        return cfg
    }
}
