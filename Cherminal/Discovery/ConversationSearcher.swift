import Foundation

/// Full-text search across conversation bodies (every `~/.claude` + `~/.codex`
/// session JSONL). Two-phase for speed + quality:
///   1. `grep -rilF` finds candidate files (optimized C byte scan — fast even
///      across ~1.6 GB).
///   2. Parse only those candidates to pull a clean snippet from the message
///      *text*, dropping hits that landed only in base64 / tool-result noise.
///
/// Pure file observation. Returns hits keyed by session-file path so the
/// sidebar can map them back to registry conversations.
enum ConversationSearcher {
    struct Hit: Sendable, Equatable {
        let path: String      // session file path
        let snippet: String   // matched text excerpt
    }

    /// Keys whose string values count as human-readable conversation text
    /// (excludes image `source`/`data` blobs and the like).
    private static let textKeys: Set<String> = ["text", "content", "lastPrompt", "aiTitle", "summary"]

    static func search(query rawQuery: String, limit: Int = 80) -> [Hit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }

        let home = NSHomeDirectory()
        let roots = [
            home + "/.claude/projects",
            home + "/.codex/sessions",
        ].filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return [] }

        // grep returns files in filesystem-walk order; sort by recency so the
        // `limit` keeps the most recently-active matches, not whatever the walk
        // happened to list first.
        let candidates = candidateFiles(query: query, roots: roots)
            .map { (path: $0, mtime: (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? nil) }
            .sorted { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }
            .map { $0.path }
        let needle = query.lowercased()

        var hits: [Hit] = []
        for path in candidates {
            if hits.count >= limit { break }
            guard let snippet = snippet(forFileAt: path, needle: needle) else { continue }
            hits.append(Hit(path: path, snippet: snippet))
        }
        return hits
    }

    // MARK: - Phase 1: candidate files via grep

    private static func candidateFiles(query: String, roots: [String]) -> [String] {
        // -r recurse, -i case-insensitive, -l files-with-matches, -F fixed
        // string (no regex), --include only jsonl, -e handles leading dashes.
        var args = ["-rilF", "--include=*.jsonl", "-e", query]
        args.append(contentsOf: roots)
        guard let out = run("/usr/bin/grep", args) else { return [] }
        return out.split(separator: "\n").map(String.init)
    }

    // MARK: - Phase 2: clean snippet from message text

    private static func snippet(forFileAt path: String, needle: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        for index in data.indices where data[index] == newline {
            if let s = snippet(inLine: data[start..<index], needle: needle) { return s }
            start = data.index(after: index)
        }
        if start < data.endIndex {
            if let s = snippet(inLine: data[start..<data.endIndex], needle: needle) { return s }
        }
        return nil  // matched only in non-text (base64/tool noise) — drop it.
    }

    private static func snippet(inLine line: Data.SubSequence, needle: String) -> String? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) else { return nil }
        var text = ""
        collectText(from: obj, into: &text, budget: 4000)
        let haystack = text.lowercased()
        guard let r = haystack.range(of: needle) else { return nil }
        return excerpt(text, around: r)
    }

    /// Recursively gather human-readable strings (allowlisted keys only).
    private static func collectText(from any: Any, into out: inout String, budget: Int) {
        guard out.count < budget else { return }
        switch any {
        case let dict as [String: Any]:
            for (key, value) in dict {
                if let s = value as? String, textKeys.contains(key) {
                    out += s + " "
                } else {
                    collectText(from: value, into: &out, budget: budget)
                }
            }
        case let arr as [Any]:
            for v in arr { collectText(from: v, into: &out, budget: budget) }
        default:
            break
        }
    }

    /// ~80-char window around the match, single-lined, with ellipses.
    private static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        let pad = 48
        let lower = text.index(range.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lower > text.startIndex { s = "…" + s }
        if upper < text.endIndex { s += "…" }
        return s
    }

    // MARK: - Subprocess

    private static func run(_ launchPath: String, _ args: [String]) -> String? {
        // grep across multi-GB of session files legitimately takes seconds —
        // give it room, but never let it wedge a search forever. (grep exits 1
        // on "no matches", which isn't an error for us — stdout() ignores status.)
        Subprocess.stdout(launchPath, args, timeout: 20)
    }
}
