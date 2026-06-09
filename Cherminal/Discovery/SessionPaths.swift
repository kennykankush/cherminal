import Foundation

/// Classifies a filesystem path reported by the watcher into "which kind of
/// session file is this, if any" — the incremental refresh must recognize
/// EXACTLY what the full scanners enumerate, or it would invent conversations
/// the full scan ignores:
///
///   • Claude sessions are `projects/<encoded-room>/<id>.jsonl` — depth
///     exactly 2. Deeper .jsonl files exist (subagent sidechains live at
///     `<room>/<session-id>/subagents/agent-*.jsonl`) and are NOT sessions.
///   • Codex rollouts are `sessions/<y>/<m>/<d>/rollout-*.jsonl` (the scanner
///     walks recursively, so depth is free; the rollout- prefix is the law).
///
/// Anything else under the watched roots (directories, subagent files, index
/// files) is ignored — same as the full scan — EXCEPT a watched root itself,
/// which FSEvents delivers on overflow and means "rescan everything".
enum SessionPaths {
    enum Kind: Equatable {
        case claudeSession
        case codexRollout
        case ignored
        case fullRescan
    }

    static func classify(_ path: String, claudeRoot: String, codexRoot: String) -> Kind {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalized == String(claudeRoot.dropLast()) || normalized == String(codexRoot.dropLast()) {
            return .fullRescan
        }
        if path.hasPrefix(claudeRoot) {
            guard path.hasSuffix(".jsonl") else { return .ignored }
            // Exactly <dir>/<file>.jsonl below the root — deeper is a sidechain.
            let relative = path.dropFirst(claudeRoot.count)
            return relative.split(separator: "/").count == 2 ? .claudeSession : .ignored
        }
        if path.hasPrefix(codexRoot) {
            guard path.hasSuffix(".jsonl"),
                  path.split(separator: "/").last?.hasPrefix("rollout-") == true
            else { return .ignored }
            return .codexRollout
        }
        return .ignored
    }
}
