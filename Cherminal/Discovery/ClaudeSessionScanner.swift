import Foundation

/// Walks `~/.claude/projects/<encoded-cwd>/*.jsonl` and produces conversation
/// summaries, hitting the persistent cache wherever possible.
///
/// Two-pass emission:
///   1. `stat` every session file. Anything whose `(path, mtime, size)` still
///      matches a cache row is emitted immediately with no I/O beyond the
///      stat itself.
///   2. Misses are parsed concurrently with a bounded TaskGroup and written
///      back to the cache as they complete.
///
/// The scanner is the only thing that should write `conversations` rows in
/// `SessionCache`. The registry layer subscribes to results via the async
/// stream returned by `scan(cache:)`.
struct ClaudeSessionScanner {
    let cache: SessionCache?

    func scan() -> AsyncStream<SessionScanEngine.Update> {
        let cache = self.cache
        return SessionScanEngine.stream(
            cache: cache,
            prepare: {},
            enumerate: { _ in Self.enumerateCandidates() },
            parse: { candidate, _ in Self.parseOne(candidate, cache: cache) }
        )
    }

    // MARK: - Stat sweep

    private static func enumerateCandidates() -> [ScanCandidate] {
        let projectsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [ScanCandidate] = []
        for dir in projectDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            guard let roomPath = PathEncoder.decode(dir.lastPathComponent) else { continue }

            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = Int64(values?.fileSize ?? 0)
                guard size > 0 else { continue }
                out.append(ScanCandidate(file: file, mtime: mtime, size: size, roomHint: roomPath.path))
            }
        }
        return out
    }

    // MARK: - Parse one

    private static func parseOne(_ candidate: ScanCandidate, cache: SessionCache?) -> Conversation? {
        let summary = (try? SessionParser.summarize(file: candidate.file)) ?? .init()
        guard summary.totalLines > 0 else {
            // Don't let it vanish without a trace — a non-empty file that yields
            // no parseable lines is a format regression worth seeing in the log.
            clog("scan", "claude: unreadable \(candidate.file.lastPathComponent) (size=\(candidate.size))")
            return nil
        }

        let lastActivity = summary.lastTimestamp ?? Date(timeIntervalSince1970: candidate.mtime)
        // Fall back to the first real user prompt so sessions without an
        // ai-title/last-prompt record (most of them) still read meaningfully.
        // A manual `/rename` (custom-title) wins; then the auto ai-title, then
        // the last prompt, then the first user message.
        let preview = summary.customTitle ?? summary.aiTitle ?? summary.lastPrompt ?? summary.firstUserMessage
        let id = candidate.file.deletingPathExtension().lastPathComponent

        // Prefer the real cwd recorded in the session over the lossy decode of
        // the encoded folder name (which mis-splits rooms whose names contain
        // a hyphen, e.g. `fantopy-hadi` → `…/fantopy/hadi`).
        let roomPath = summary.cwd ?? candidate.roomHint ?? NSHomeDirectory()

        let persisted = SessionCache.PersistedSummary(
            id: id,
            agentRaw: AgentKind.claudeCode.rawValue,
            roomPath: roomPath,
            firstTimestamp: summary.firstTimestamp,
            lastTimestamp: lastActivity,
            messageCount: summary.userMessageCount,
            previewText: preview,
            continuedFromSessionID: detectContinuedFrom(file: candidate.file, selfID: id),
            continuationScanned: true
        )
        cache?.put(path: candidate.file.path,
                   mtime: candidate.mtime,
                   size: candidate.size,
                   summary: persisted)

        return Conversation(persisted: persisted, sessionFile: candidate.file)
    }

    // MARK: - Compaction-chain detection

    private static let continuationPhrase = "Continue the conversation from where it left off"

    /// Detect whether this session is a post-compaction *continuation* of
    /// another. When Claude compacts a full conversation it starts a new session
    /// whose first user turn embeds the parent's `…/<uuid>.jsonl` path immediately
    /// followed by the "Continue the conversation from where it left off" handoff.
    /// Returns the parent session id, or nil.
    ///
    /// The marker lives in the first user record — past the title/mode/snapshot
    /// records, so beyond the 16 KB the summary parser reads — so we scan a
    /// bounded head (512 KB) here. Reads stop there, so an unusually large
    /// pre-turn snapshot just yields no detection (no harm, just no badge).
    private static func detectContinuedFrom(file: URL, selfID: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512 * 1024), !head.isEmpty else { return nil }
        let text = String(decoding: head, as: UTF8.self) as NSString
        // The handoff is specifically "<parent>.jsonl" immediately followed by the
        // continuation phrase. Anchor on the *path* and require the phrase right
        // after it — don't anchor on the phrase, which can also appear inside the
        // compaction summary above the real handoff (then there'd be no UUID just
        // before it and we'd wrongly bail).
        let uuidJsonl = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.jsonl"#
        guard let re = try? NSRegularExpression(pattern: uuidJsonl) else { return nil }
        let full = NSRange(location: 0, length: text.length)
        for m in re.matches(in: text as String, range: full) {
            // Probe the few chars after "<uuid>.jsonl" (just an escaped newline in
            // the handoff) for the phrase.
            let probeStart = m.range.location + m.range.length
            let probeLen = min(continuationPhrase.count + 8, text.length - probeStart)
            guard probeLen > 0 else { continue }
            let probe = text.substring(with: NSRange(location: probeStart, length: probeLen))
            guard probe.contains(continuationPhrase) else { continue }
            let parent = String(text.substring(with: m.range).dropLast(6))   // strip ".jsonl"
            if parent != selfID { return parent }
        }
        return nil
    }
}

// MARK: - Conversion

extension Conversation {
    init?(persisted: SessionCache.PersistedSummary, sessionFile: URL) {
        guard let agent = AgentKind(rawValue: persisted.agentRaw) else { return nil }
        self.init(
            id: persisted.id,
            agent: agent,
            roomPath: URL(fileURLWithPath: persisted.roomPath),
            sessionFile: sessionFile,
            firstMessageAt: persisted.firstTimestamp,
            lastActivityAt: persisted.lastTimestamp,
            messageCount: persisted.messageCount,
            previewText: persisted.previewText,
            state: .dormant,
            continuedFromID: persisted.continuedFromSessionID
        )
    }
}
