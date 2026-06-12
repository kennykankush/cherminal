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
            // Quote the binary: a resolved path with a space/quote in it must
            // not be able to split the inner shell line. The id is alphabet-
            // checked above, so it interpolates bare.
            let bin = Subprocess.quote(BinaryResolver.shared.path(for: "claude"))
            return Dtach.wrap("\(bin) --dangerously-skip-permissions --resume \(id)", id: id)
        case .codex:
            guard let id = safeSessionID(conversation.id) else { return nil }
            let bin = Subprocess.quote(BinaryResolver.shared.path(for: "codex"))
            return Dtach.wrap("\(bin) --dangerously-bypass-approvals-and-sandbox resume \(id)", id: id)
        case .shell:
            // Default: no command override → Ghostty spawns the user's login
            // shell in `cfg.workingDirectory`. Wrap it under dtach (socket keyed on
            // the pane's stable conversation id) when persistent sessions are on
            // (cold-start a survivable shell) OR when a master already exists for
            // this id — so a shell wrapped while the pref was on still REATTACHES
            // live (`dtach -A` is reattach-or-create) after the pref is toggled
            // off, and on launch restore, instead of cold-starting a raw shell and
            // orphaning the live master.
            guard let id = safeSessionID(conversation.id),
                  Dtach.wrapAllPanes || Dtach.isMasterAlive(id: id) else { return nil }
            return Dtach.wrap("exec ${SHELL:-/bin/zsh} -il", id: id)
        case .unknown:
            // Unclassified fallback — keep it a plain raw shell (no override).
            // Deliberately NOT dtach-wrapped/persisted: we can't classify or
            // reliably reconstruct it on restore, so an ephemeral shell avoids a
            // parked master with no tray cell or reattach path. (It therefore has
            // no master, so detachToTray's liveness check never parks it.)
            return nil
        }
    }

    /// The plain resume line — no dtach wrap, PATH binary names — for the
    /// inspector's "Copy resume command": paste into any terminal anywhere.
    /// Same bypass flags as resume(); same injection guard.
    static func copyableResume(for conversation: Conversation) -> String? {
        guard let id = safeSessionID(conversation.id) else { return nil }
        switch conversation.agent {
        case .claudeCode: return "claude --dangerously-skip-permissions --resume \(id)"
        case .codex:      return "codex --dangerously-bypass-approvals-and-sandbox resume \(id)"
        default:          return nil
        }
    }

    /// Attach to a session registered with claude's background-agent
    /// supervisor (`claude attach <id>` — ^Z detaches, the session keeps
    /// running). dtach-wrapped on the session's own socket like every agent
    /// pane, so the attach VIEW also survives quit/park — and if the user
    /// later opens the same conversation normally, `dtach -A` reattaches this
    /// same master instead of spawning a competitor.
    ///
    /// `|| exec --resume` is the graceful-degradation tail: when the
    /// supervisor session has ENDED, `attach` exits nonzero in ~200ms ("No
    /// job matching…") — without the fallback that surfaced as Ghostty's
    /// failed-to-launch banner and a dead black pane. Now the same pane
    /// seamlessly cold-resumes the conversation instead (the exact manual
    /// recovery: kill + reopen — automated). A DELIBERATE ^Z detach exits 0,
    /// so it never triggers the fallback.
    static func attachBackground(claudeSessionID id: String) -> String? {
        guard let id = safeSessionID(id) else { return nil }
        let bin = Subprocess.quote(BinaryResolver.shared.path(for: "claude"))
        return Dtach.wrap(
            "\(bin) attach \(id) || exec \(bin) --dangerously-skip-permissions --resume \(id)",
            id: id)
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

    /// `commandOverride` replaces the conversation-derived resume command —
    /// the background-attach path uses it (same cwd/env handling either way).
    static func surfaceConfig(
        for conversation: Conversation,
        commandOverride: String? = nil
    ) -> Ghostty.SurfaceConfiguration {
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

        cfg.command = commandOverride ?? resume(for: conversation)
        cfg.environmentVariables = BinaryResolver.shared.environment()
        return cfg
    }
}
