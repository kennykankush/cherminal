import Foundation

/// Decides — purely by reading an agent's session JSONL — whether the agent
/// has finished its turn and is now waiting on you. This is what drives the
/// calm blue "your turn" light in the sidebar: no terminal bell, no hooks, no
/// injection. Just the conversation's own on-disk state (observe-externally).
///
/// Signals, one per agent:
///  - Claude Code: the most recent `assistant` message carries a `stop_reason`.
///    `end_turn` means the model handed control back to you; `tool_use` means
///    it's mid-task and about to run a tool (still working).
///  - Codex: each completed turn ends with a `task_complete` event record, so
///    the agent is awaiting you exactly when that's the last line written.
enum TurnState {
    /// `awaitingUser`: the agent finished and it's your turn. `size`: the
    /// session file's current byte length, used by the caller as a monotonic
    /// marker so a turn you've already seen doesn't re-light.
    struct Reading { let awaitingUser: Bool; let size: UInt64 }

    /// Read the tail of `sessionFile` and classify the latest turn. Cheap: a
    /// bounded tail read + a little JSON, fine to call on the poll loop.
    static func read(sessionFile: URL, agent: AgentKind) -> Reading {
        guard let fh = try? FileHandle(forReadingFrom: sessionFile) else {
            return Reading(awaitingUser: false, size: 0)
        }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        // The turn boundary is always within the last record or two; a 64K tail
        // covers even a very large final assistant message.
        let tail: UInt64 = 64 * 1024
        try? fh.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? fh.readToEnd(), !data.isEmpty else {
            return Reading(awaitingUser: false, size: size)
        }

        let newline = UInt8(ascii: "\n")
        let lines = data.split(separator: newline, omittingEmptySubsequences: true)
        let awaiting: Bool
        switch agent {
        case .claudeCode: awaiting = claudeAwaiting(lines)
        case .codex:      awaiting = codexAwaiting(lines)
        default:          awaiting = false
        }
        return Reading(awaitingUser: awaiting, size: size)
    }

    /// The most recent assistant message decides: `end_turn` → awaiting you;
    /// `tool_use` (or a trailing user/tool-result record) → still working.
    /// Trailing non-conversational records (summaries, file-history snapshots)
    /// are skipped so they can't mask the real turn boundary.
    ///
    /// Verified against real sessions (2026-06): subagent sidechains can NOT
    /// pollute this read — their records live in separate files
    /// (`<room>/<session-id>/subagents/agent-*.jsonl`), never in the main
    /// session JSONL (whose records all carry isSidechain:false). While
    /// subagents run, the main file's last assistant record is the
    /// orchestrator's `tool_use` → correctly "working". Streaming partials
    /// carry stop_reason null → also "working".
    private static func claudeAwaiting(_ lines: [Data.SubSequence]) -> Bool {
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "assistant" {
                let stop = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                return stop == "end_turn" || stop == "stop_sequence"
            }
            if type == "user" {
                // A user / tool-result record after the last assistant message
                // means the agent is about to continue — not your turn yet.
                return false
            }
        }
        return false
    }

    /// Codex closes each turn with a `task_complete` event. In every observed
    /// rollout it's the literal last line (the order is …, token_count,
    /// task_complete), but the scan walks backward skipping benign bookkeeping
    /// trailers (token_count) so a future write-order flip can't silently kill
    /// the light. The FIRST substantive record from the end decides: a
    /// task_complete → your turn; anything else (a user_message, a streaming
    /// assistant message, a tool call) → a newer turn is underway.
    private static func codexAwaiting(_ lines: [Data.SubSequence]) -> Bool {
        for line in lines.suffix(6).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            switch type {
            case "task_complete": return true
            case "token_count": continue   // bookkeeping, not turn activity
            default: return false
            }
        }
        return false
    }
}
