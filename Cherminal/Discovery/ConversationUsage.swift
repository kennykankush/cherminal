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

/// Parses one Claude Code session JSONL into a `ConversationUsage`. Reads the
/// whole file (cheap for a single active conversation) and dedups usage rows
/// by `(messageId|requestId)` keeping the max output, because Claude appends
/// multiple usage rows per message as a turn streams.
enum ConversationUsageParser {
    static func parse(sessionFile: URL) -> ConversationUsage? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }

        struct Row { var input = 0; var output = 0; var cacheRead = 0; var cacheCreate = 0 }
        var byKey: [String: Row] = [:]
        var model: String?
        var lastInput = 0, lastOutput = 0, lastCacheRead = 0, lastCacheCreate = 0

        func handle(_ line: Data.SubSequence) {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            if let m = message["model"] as? String, !m.isEmpty { model = m }

            let input = intValue(usage["input_tokens"])
            let output = intValue(usage["output_tokens"])
            let cacheRead = intValue(usage["cache_read_input_tokens"])
            let cacheCreate = intValue(usage["cache_creation_input_tokens"])

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

            // Track the latest turn for the context-fill calc (input > 1 skips
            // the cache-only continuation rows).
            if input > 1 { lastInput = input }
            if output > 0 { lastOutput = output }
            if cacheRead > 0 { lastCacheRead = cacheRead }
            if cacheCreate > 0 { lastCacheCreate = cacheCreate }
        }

        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        for index in data.indices where data[index] == newline {
            handle(data[start..<index])
            start = data.index(after: index)
        }
        if start < data.endIndex { handle(data[start..<data.endIndex]) }

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
            contextWindowTokens: inferContextWindow(model: model, observedUsed: contextUsed),
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            cacheCreateTokens: totalCacheCreate
        )
    }

    /// Mirror of burnrate's model→context-window inference, with a guard that
    /// bumps to 1M if we observe a turn larger than the inferred base.
    private static func inferContextWindow(model: String?, observedUsed: Int) -> Int {
        let lowered = (model ?? "").lowercased()
        let base: Int
        if lowered.contains("[1m]")
            || lowered.contains("opus-4-7")
            || lowered.contains("sonnet-4-6") {
            base = 1_000_000
        } else {
            base = 200_000
        }
        return observedUsed > base ? 1_000_000 : base
    }

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        default: return 0
        }
    }
}
