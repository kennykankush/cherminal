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
    static func resume(for conversation: Conversation) -> String? {
        switch conversation.agent {
        case .claudeCode:
            let bin = BinaryResolver.shared.path(for: "claude")
            return "\(bin) --dangerously-skip-permissions --resume \(conversation.id)"
        case .codex:
            let bin = BinaryResolver.shared.path(for: "codex")
            return "\(bin) --dangerously-bypass-approvals-and-sandbox resume \(conversation.id)"
        case .shell, .unknown:
            // No command override → Ghostty spawns the user's default shell
            // in `cfg.workingDirectory`.
            return nil
        }
    }

    static func surfaceConfig(for conversation: Conversation) -> Ghostty.SurfaceConfiguration {
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.workingDirectory = conversation.roomPath.path
        cfg.command = resume(for: conversation)
        cfg.environmentVariables = BinaryResolver.shared.environment()
        return cfg
    }
}
