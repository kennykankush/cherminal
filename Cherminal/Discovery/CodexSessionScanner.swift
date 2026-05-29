import Foundation

/// Walks `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl` and produces
/// conversation summaries for Codex sessions.
///
/// Two metadata sources are used together:
///   • `~/.codex/session_index.jsonl` — Codex's own precomputed index. One
///     line per session with `{id, thread_name, updated_at}`. We use it for
///     the human-readable title; it's also our cheapest signal that a
///     session has been finalized.
///   • Rollout file `session_meta` record (always line 1) — gives us the
///     `cwd` so we know which room the session belongs to.
///
/// Cache-aware. Two-pass emission (hits first, misses parsed concurrently).
struct CodexSessionScanner {
    let cache: SessionCache?

    func scan() -> AsyncStream<SessionScanEngine.Update> {
        let cache = self.cache
        return SessionScanEngine.stream(
            cache: cache,
            // Prep: read Codex's title index once, hand it to every parse.
            prepare: { Self.readTitleIndex() },
            enumerate: { _ in Self.enumerateRolloutFiles() },
            parse: { candidate, titles in Self.parseOne(candidate, titles: titles, cache: cache) }
        )
    }

    // MARK: - Title index

    /// Build {session-id → thread_name} from `session_index.jsonl`. Duplicates
    /// in the file are normal (Codex appends a new line each time a session
    /// is finalized); we keep the most recent name.
    private static func readTitleIndex() -> [String: String] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var out: [String: String] = [:]
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        for index in data.indices {
            guard data[index] == newline else { continue }
            ingest(line: data[start..<index], into: &out)
            start = data.index(after: index)
        }
        if start < data.endIndex {
            ingest(line: data[start..<data.endIndex], into: &out)
        }
        return out
    }

    private static func ingest(line: Data.SubSequence, into out: inout [String: String]) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard let id = obj["id"] as? String, let name = obj["thread_name"] as? String, !name.isEmpty else { return }
        out[id] = name
    }

    // MARK: - File enumeration

    private static func enumerateRolloutFiles() -> [ScanCandidate] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [ScanCandidate] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = Int64(values?.fileSize ?? 0)
            guard size > 0 else { continue }
            // Codex carries its cwd in-file (session_meta), so no room hint.
            out.append(ScanCandidate(file: url, mtime: mtime, size: size, roomHint: nil))
        }
        return out
    }

    // MARK: - Parse one

    private static func parseOne(
        _ candidate: ScanCandidate,
        titles: [String: String],
        cache: SessionCache?
    ) -> Conversation? {
        guard let meta = parseSessionMeta(from: candidate.file) else {
            clog("scan", "codex: no session_meta in \(candidate.file.lastPathComponent) (size=\(candidate.size))")
            return nil
        }
        let id = meta.id
        let cwd = meta.cwd
        let firstTimestamp = meta.timestamp

        // For Codex the tail of the file is structurally heavier than Claude
        // (response_item records, not single-line user prompts), but we only
        // need a last activity timestamp. Read the tail and grab the most
        // recent `timestamp` field.
        let lastTimestamp = parseLastTimestamp(from: candidate.file) ?? firstTimestamp

        // Codex's title index covers almost nothing, so fall back to the
        // first real user prompt in the rollout (skipping injected wrapper
        // blocks). Turns the sea of "Untitled" into something readable.
        let preview = titles[id] ?? parseFirstUserMessage(from: candidate.file)

        let persisted = SessionCache.PersistedSummary(
            id: id,
            agentRaw: AgentKind.codex.rawValue,
            roomPath: cwd,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: 0, // Codex's record types make this expensive; skip for v0.1.
            previewText: preview
        )
        cache?.put(path: candidate.file.path,
                   mtime: candidate.mtime,
                   size: candidate.size,
                   summary: persisted)

        return Conversation(persisted: persisted, sessionFile: candidate.file)
    }

    // MARK: - First user message (title fallback)

    /// Scan the start of the rollout for the first *real* user prompt — a
    /// `response_item` message with `role: user` whose text isn't an injected
    /// wrapper (`<environment_context>`, `<user_instructions>`, command tags).
    private static func parseFirstUserMessage(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // 512 KB covers the (large) session_meta line plus the first several
        // records — the real prompt is always within them.
        let window = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        let newline = UInt8(ascii: "\n")
        var lines = window.split(separator: newline, omittingEmptySubsequences: true)
        guard lines.count > 1 else { return nil }
        lines.removeFirst()  // skip session_meta

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (obj["type"] as? String) == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["role"] as? String) == "user",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            for block in content {
                if let text = block["text"] as? String, let title = codexTitle(from: text) {
                    return title
                }
            }
        }
        return nil
    }

    /// Clean a Codex user text into a title, or nil if it's wrapper/system noise.
    private static func codexTitle(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("<environment_context") || lowered.hasPrefix("<user_instructions")
            || lowered.hasPrefix("<command") || lowered.hasPrefix("<local-command")
            || lowered.hasPrefix("caveat:") || trimmed.hasPrefix("[Request interrupted") {
            return nil
        }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- ").union(.whitespaces))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(120))
    }

    // MARK: - Session_meta extraction

    private struct CodexMeta {
        let id: String
        let cwd: String
        let timestamp: Date
    }

    /// `session_meta` is always the first line of a Codex rollout file, but
    /// that line is huge — the embedded `base_instructions.text` alone runs
    /// tens of KB. A fixed-size head read isn't safe; we chunk-read until we
    /// hit the first newline, capped at 1 MB to guard against malformed
    /// files (none observed in the wild, but worth a ceiling).
    private static func parseSessionMeta(from url: URL) -> CodexMeta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let ceiling = 1024 * 1024
        var collected = Data()
        while collected.firstIndex(of: UInt8(ascii: "\n")) == nil, collected.count < ceiling {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            collected.append(chunk)
        }

        guard let newlineIndex = collected.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let firstLine = collected[collected.startIndex..<newlineIndex]
        guard let obj = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any] else { return nil }
        guard (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String else { return nil }

        let timestampString = (payload["timestamp"] as? String) ?? (obj["timestamp"] as? String) ?? ""
        let ts = isoDate(from: timestampString) ?? Date()
        return CodexMeta(id: id, cwd: cwd, timestamp: ts)
    }

    /// Read the last 8KB of the file, scan from the end backward through the
    /// JSON-Lines records, return the most recent `timestamp` field we find.
    private static func parseLastTimestamp(from url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 8 * 1024
        let from: UInt64 = size > chunk ? size - chunk : 0
        try? handle.seek(toOffset: from)
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty else { return nil }

        // Walk lines in reverse.
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex
        while end > data.startIndex {
            guard let lineStart = data[data.startIndex..<end].lastIndex(of: newline) else {
                // Final unterminated chunk at the head — skip; it may be partial.
                break
            }
            let line = data[data.index(after: lineStart)..<end]
            end = lineStart
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let ts = obj["timestamp"] as? String,
               let date = isoDate(from: ts) {
                return date
            }
        }
        return nil
    }

    // Shared formatters — `isoDate` is called per line while reverse-scanning
    // the tail, so allocating two formatters per call added up on cold scans.
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoDate(from string: String) -> Date? {
        if string.isEmpty { return nil }
        if let d = isoFraction.date(from: string) { return d }
        return isoPlain.date(from: string)
    }
}
