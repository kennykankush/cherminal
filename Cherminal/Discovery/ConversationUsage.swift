import Foundation

/// Per-conversation usage derived from a Claude Code session JSONL — context
/// window fill, token totals, and cache efficiency. Adapted from burnrate's
/// (`~/dev/ai-usage-app`) parse + context math, scoped to a single session
/// and kept fully local (no network, no Keychain) per Cherminal's
/// observe-externally rule. Account-wide 5h/weekly rate-limit windows are
/// deliberately out of scope here — those need the Anthropic OAuth endpoint.
struct ConversationUsage: Sendable, Equatable {
    var model: String?
    /// The most recent assistant turn's footprint — i.e. current context size.
    var contextUsedTokens: Int
    var contextWindowTokens: Int
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var cacheReadTokens: Int
    var cacheCreateTokens: Int
    /// Exact user-message count, derived from the same full pass we already do
    /// for token math. nil when we can't count truthfully (Codex, where the
    /// record format makes a tail-only read insufficient) — the UI hides the
    /// row rather than show a wrong number.
    var messageCount: Int? = nil
    /// Account-wide rate-limit windows. Codex records these in-file
    /// (primary = 5h, secondary = weekly); Claude would need the OAuth API,
    /// so they stay empty there for now.
    var rateWindows: [RateWindow] = []

    struct RateWindow: Sendable, Equatable, Identifiable {
        let label: String        // "5h" / "Weekly"
        let usedPercent: Double  // 0–100
        let resetsAt: Date?
        var id: String { label }
    }

    var contextUsedPercent: Double {
        guard contextWindowTokens > 0 else { return 0 }
        return min(100, Double(contextUsedTokens) / Double(contextWindowTokens) * 100)
    }

    var contextRemainingTokens: Int {
        max(0, contextWindowTokens - contextUsedTokens)
    }

    /// Share of input that was served from cache — high is good (cheaper, faster).
    var cacheHitPercent: Double {
        let denom = totalInputTokens + cacheReadTokens
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(denom) * 100
    }

    var totalTokens: Int {
        totalInputTokens + totalOutputTokens + cacheReadTokens + cacheCreateTokens
    }

    /// "Opus 4.7 (1M)" from "claude-opus-4-7[1m]".
    var modelDisplayName: String? {
        guard var s = model, !s.isEmpty else { return nil }
        if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
        let oneMillion = s.contains("[1m]")
        s = s.replacingOccurrences(of: "[1m]", with: "")
        // opus-4-7 -> Opus 4.7
        let parts = s.split(separator: "-")
        var name = parts.first.map { $0.capitalized } ?? s
        let version = parts.dropFirst().joined(separator: ".")
        if !version.isEmpty { name += " " + version }
        return oneMillion ? name + " (1M)" : name
    }
}

/// Resumable accumulator for Claude usage. The live context gauge polls every
/// few seconds; rather than re-read and re-parse the whole session each time,
/// this folds in only the bytes appended since the last poll (JSONL is
/// append-only). Dedup-by-key keeping the max means each usage row is counted
/// exactly once as it streams in — re-reading earlier bytes is unnecessary.
///
/// Mutated only from the serialized poll loop (one `ingest` at a time), so the
/// unchecked Sendable conformance is sound.
final class ClaudeUsageAccumulator: @unchecked Sendable {
    private struct Row { var input = 0; var output = 0; var cacheRead = 0; var cacheCreate = 0 }
    private var byKey: [String: Row] = [:]
    private var model: String?
    private var lastInput = 0, lastOutput = 0, lastCacheRead = 0, lastCacheCreate = 0
    private var userMessages = 0     // real count of non-echo user turns
    private var offset: UInt64 = 0   // bytes folded in; always ends on a newline

    /// Fold in newly-appended lines and return the current usage (nil until at
    /// least one assistant/usage row has been seen).
    func ingest(file: URL) -> ConversationUsage? {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return snapshot() }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { reset() }                     // rotated / truncated — start over
        guard size > offset else { return snapshot() }   // nothing new since last poll

        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return snapshot() }

        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        var consumed = 0
        for index in data.indices where data[index] == newline {
            fold(line: data[start..<index])
            let next = data.index(after: index)
            consumed = data.distance(from: data.startIndex, to: next)
            start = next
        }
        // Leave any trailing partial line (a half-written turn) for the next poll.
        offset += UInt64(consumed)
        return snapshot()
    }

    private func reset() {
        byKey.removeAll(); model = nil
        lastInput = 0; lastOutput = 0; lastCacheRead = 0; lastCacheCreate = 0
        userMessages = 0
        offset = 0
    }

    private func fold(line: Data.SubSequence) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = obj["type"] as? String

        // Count real user turns — skip the tool-result echoes Claude writes back
        // as synthetic "user" records, same rule the sidebar parser uses.
        if type == "user" {
            if let message = obj["message"] as? [String: Any],
               let content = message["content"], !Self.isToolResultEcho(content) {
                userMessages += 1
            }
            return
        }

        guard type == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }

        if let m = message["model"] as? String, !m.isEmpty { model = m }

        let input = ConversationUsageParser.intValue(usage["input_tokens"])
        let output = ConversationUsageParser.intValue(usage["output_tokens"])
        let cacheRead = ConversationUsageParser.intValue(usage["cache_read_input_tokens"])
        let cacheCreate = ConversationUsageParser.intValue(usage["cache_creation_input_tokens"])

        let messageId = (message["id"] as? String) ?? ""
        let requestId = (obj["requestId"] as? String) ?? ""
        let key = "\(messageId)|\(requestId)"
        let existing = byKey[key] ?? Row()
        byKey[key] = Row(
            input: max(existing.input, input),
            output: max(existing.output, output),
            cacheRead: max(existing.cacheRead, cacheRead),
            cacheCreate: max(existing.cacheCreate, cacheCreate)
        )

        // The context-window footprint is the latest *real* turn (input > 1
        // skips cache-only continuation rows). Capture all four components from
        // that one turn ATOMICALLY — independent per-field ">0" guards would
        // keep stale cache values after a /compact, where the new turn
        // legitimately reports cacheRead/cacheCreate = 0, over-reporting the
        // gauge (and even flipping a 200K model into the 1M bucket).
        if input > 1 {
            lastInput = input
            lastOutput = output
            lastCacheRead = cacheRead
            lastCacheCreate = cacheCreate
        }
    }

    /// Claude writes tool results back as synthetic `user` records; those aren't
    /// real user turns, so they don't count toward the message total.
    private static func isToolResultEcho(_ content: Any) -> Bool {
        if let array = content as? [[String: Any]],
           array.contains(where: { ($0["type"] as? String) == "tool_result" }) {
            return true
        }
        return false
    }

    private func snapshot() -> ConversationUsage? {
        guard !byKey.isEmpty else { return nil }
        var totalInput = 0, totalOutput = 0, totalCacheRead = 0, totalCacheCreate = 0
        for row in byKey.values {
            totalInput += row.input
            totalOutput += row.output
            totalCacheRead += row.cacheRead
            totalCacheCreate += row.cacheCreate
        }
        let contextUsed = lastInput + lastCacheRead + lastCacheCreate + lastOutput
        return ConversationUsage(
            model: model,
            contextUsedTokens: contextUsed,
            contextWindowTokens: ConversationUsageParser.inferContextWindow(model: model, observedUsed: contextUsed),
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            cacheCreateTokens: totalCacheCreate,
            messageCount: userMessages
        )
    }
}

/// Parses Claude / Codex session JSONL into a `ConversationUsage`. Claude usage
/// streams append-only, so the live gauge folds in deltas via
/// `ClaudeUsageAccumulator`; Codex carries a full `token_count` record we read
/// from the tail.
enum ConversationUsageParser {
    /// One-shot full parse (folds the whole file in a single pass).
    static func parse(sessionFile: URL) -> ConversationUsage? {
        ClaudeUsageAccumulator().ingest(file: sessionFile)
    }

    /// Model substrings known to ship a 1M-token context window. This list
    /// ages — keep it current — but it's not load-bearing: the
    /// `observedUsed > base` guard below means an unknown 1M model still
    /// self-corrects the moment its context grows past the 200K base.
    private static let oneMillionContextMarkers = ["[1m]", "opus-4-7", "opus-4-8", "sonnet-4-6"]

    /// Mirror of burnrate's model→context-window inference, with a guard that
    /// bumps to 1M if we observe a turn larger than the inferred base.
    fileprivate static func inferContextWindow(model: String?, observedUsed: Int) -> Int {
        let lowered = (model ?? "").lowercased()
        let base = oneMillionContextMarkers.contains { lowered.contains($0) } ? 1_000_000 : 200_000
        return observedUsed > base ? 1_000_000 : base
    }

    fileprivate static func intValue(_ any: Any?) -> Int {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        default: return 0
        }
    }

    // MARK: - Codex

    /// Codex rollouts emit `event_msg` / `token_count` records carrying the
    /// real context window, full token usage, and the 5h + weekly rate-limit
    /// windows. We read the file tail and use the latest such record.
    static func parseCodex(sessionFile: URL) -> ConversationUsage? {
        guard let handle = try? FileHandle(forReadingFrom: sessionFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailLen: UInt64 = 1_000_000
        try? handle.seek(toOffset: size > tailLen ? size - tailLen : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        // Scan lines from the end for the latest token_count with populated info.
        let newline = UInt8(ascii: "\n")
        let lines = data.split(separator: newline, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }

            let total = info["total_token_usage"] as? [String: Any] ?? [:]
            let last = info["last_token_usage"] as? [String: Any] ?? [:]
            let window = intValue(info["model_context_window"])

            // Codex's input_tokens already includes cached_input_tokens; split
            // them so cache-hit math matches Claude's (fresh input vs cached).
            let cached = intValue(total["cached_input_tokens"])
            let freshInput = max(0, intValue(total["input_tokens"]) - cached)
            let used = intValue(last["total_tokens"])
            var usage = ConversationUsage(
                model: "Codex",
                contextUsedTokens: used,
                // Never let the window read smaller than what's already used, so
                // the gauge can't show "260k / 256k" (Claude self-corrects via
                // inferContextWindow; Codex needs this clamp).
                contextWindowTokens: max(window > 0 ? window : 256_000, used),
                totalInputTokens: freshInput,
                totalOutputTokens: intValue(total["output_tokens"]),
                cacheReadTokens: cached,
                cacheCreateTokens: 0
            )

            if let limits = payload["rate_limits"] as? [String: Any] {
                usage.rateWindows = [
                    rateWindow(limits["primary"], label: "5h"),
                    rateWindow(limits["secondary"], label: "Weekly"),
                ].compactMap { $0 }
            }
            return usage
        }
        return nil
    }

    private static func rateWindow(_ any: Any?, label: String) -> ConversationUsage.RateWindow? {
        guard let dict = any as? [String: Any] else { return nil }
        let pct = (dict["used_percent"] as? Double) ?? Double(intValue(dict["used_percent"]))
        let resets = (dict["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (intValue(dict["resets_at"]) > 0 ? Date(timeIntervalSince1970: Double(intValue(dict["resets_at"]))) : nil)
        return ConversationUsage.RateWindow(label: label, usedPercent: pct, resetsAt: resets)
    }
}
