import Foundation

/// Extracts the bits of a Claude Code session JSONL the sidebar needs:
/// title, last prompt, first/last timestamp, message count, total lines.
///
/// Strategy is head+tail: `ai-title` lands near the top of the file (set
/// within the first few turns) and `last-prompt` / latest `timestamp` live
/// at the tail. Reading just the head and tail turns multi-MB sessions
/// into single-syscall reads. We fall back to a full scan only when the
/// expected signal didn't surface.
enum SessionParser {
    static let headBytes: Int = 16 * 1024
    static let tailBytes: Int = 16 * 1024

    struct Summary: Sendable {
        var aiTitle: String?
        var lastPrompt: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var userMessageCount: Int = 0
        var totalLines: Int = 0
        /// The real working directory recorded in the session. Authoritative
        /// for the room — the encoded folder name can't be reversed when a
        /// room name contains a hyphen (e.g. `fantopy-hadi`).
        var cwd: String?
    }

    static func summarize(file: URL) throws -> Summary {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        // Small files: read the whole thing. Avoids the cost of two range
        // reads when the file fits in a single buffer anyway.
        if size <= UInt64(headBytes + tailBytes) {
            let data = try handle.readToEnd() ?? Data()
            return summarize(data: data, isCompleteFile: true)
        }

        // Head: from byte 0, always starts on a line boundary.
        try? handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: headBytes) ?? Data()

        // Tail: read the last `tailBytes` and skip leading partial line.
        try? handle.seek(toOffset: size - UInt64(tailBytes))
        let tailRaw = try handle.read(upToCount: tailBytes) ?? Data()
        let tail = stripLeadingPartialLine(tailRaw)

        var summary = parseLines(in: head, scope: .head)
        let tailSummary = parseLines(in: tail, scope: .tail)

        // Tail wins on last-prompt, lastTimestamp. Head wins on aiTitle,
        // firstTimestamp.
        if let last = tailSummary.lastPrompt { summary.lastPrompt = last }
        if let ts = tailSummary.lastTimestamp { summary.lastTimestamp = ts }
        if summary.lastTimestamp == nil { summary.lastTimestamp = tailSummary.lastTimestamp }
        if summary.firstTimestamp == nil { summary.firstTimestamp = tailSummary.firstTimestamp }
        if tailSummary.aiTitle != nil, summary.aiTitle == nil { summary.aiTitle = tailSummary.aiTitle }
        if summary.cwd == nil { summary.cwd = tailSummary.cwd }

        // Message count and line count from head+tail are a lower bound. For
        // an exact count we'd need the full file; rough is good enough for
        // the sidebar.
        summary.userMessageCount = summary.userMessageCount + tailSummary.userMessageCount
        summary.totalLines = summary.totalLines + tailSummary.totalLines

        // Fall back to a full scan only if we still don't have a last
        // timestamp — that means the tail buffer didn't land on a usable
        // line (extremely unusual; only happens on truncated files).
        if summary.lastTimestamp == nil {
            try? handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            return summarize(data: data, isCompleteFile: true)
        }

        return summary
    }

    // MARK: - Internals

    private enum Scope { case head, tail }

    private static func parseLines(in data: Data, scope: Scope) -> Summary {
        var summary = Summary()
        guard !data.isEmpty else { return summary }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        var start = data.startIndex
        let newline = UInt8(ascii: "\n")

        for index in data.indices {
            guard data[index] == newline else { continue }
            ingest(line: data[start..<index],
                   into: &summary,
                   iso: iso,
                   isoPlain: isoPlain)
            start = data.index(after: index)
        }
        // Don't ingest a trailing partial line — head/tail boundaries lie.
        if scope == .tail, start < data.endIndex {
            ingest(line: data[start..<data.endIndex],
                   into: &summary,
                   iso: iso,
                   isoPlain: isoPlain)
        } else if scope == .head, start < data.endIndex {
            // Head can have a complete final line if the buffer ended on
            // EOF without a newline (small files); main path already
            // handled that case via `isCompleteFile`, so skip here to
            // avoid double-counting partial JSON.
        }
        return summary
    }

    private static func ingest(
        line: Data.SubSequence,
        into summary: inout Summary,
        iso: ISO8601DateFormatter,
        isoPlain: ISO8601DateFormatter
    ) {
        summary.totalLines += 1
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        if summary.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            summary.cwd = cwd
        }

        if let ts = obj["timestamp"] as? String {
            let parsed = iso.date(from: ts) ?? isoPlain.date(from: ts)
            if let date = parsed {
                if summary.firstTimestamp == nil { summary.firstTimestamp = date }
                summary.lastTimestamp = date
            }
        }

        switch obj["type"] as? String {
        case "ai-title":
            if let title = obj["aiTitle"] as? String, !title.isEmpty {
                summary.aiTitle = title
            }
        case "last-prompt":
            if let prompt = obj["lastPrompt"] as? String, !prompt.isEmpty {
                summary.lastPrompt = prompt
            }
        case "user":
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"], !isToolResultEcho(content) {
                summary.userMessageCount += 1
            }
        default:
            break
        }
    }

    private static func isToolResultEcho(_ content: Any) -> Bool {
        if let array = content as? [[String: Any]],
           array.contains(where: { ($0["type"] as? String) == "tool_result" }) {
            return true
        }
        return false
    }

    /// Drop bytes before the first newline. The tail buffer starts mid-line;
    /// the first complete JSON object only begins after the first `\n`.
    private static func stripLeadingPartialLine(_ data: Data) -> Data {
        let newline = UInt8(ascii: "\n")
        guard let first = data.firstIndex(of: newline) else { return Data() }
        return data.subdata(in: data.index(after: first)..<data.endIndex)
    }

    private static func summarize(data: Data, isCompleteFile: Bool) -> Summary {
        var summary = parseLines(in: data, scope: .head)
        // For complete files we also want any trailing line that didn't end
        // in a newline.
        if isCompleteFile, let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            let trailing = data[data.index(after: lastNewline)..<data.endIndex]
            if !trailing.isEmpty {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let isoPlain = ISO8601DateFormatter()
                isoPlain.formatOptions = [.withInternetDateTime]
                ingest(line: trailing, into: &summary, iso: iso, isoPlain: isoPlain)
            }
        }
        return summary
    }
}
