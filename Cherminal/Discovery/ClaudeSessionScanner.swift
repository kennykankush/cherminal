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
        let preview = summary.aiTitle ?? summary.lastPrompt ?? summary.firstUserMessage
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
            previewText: preview
        )
        cache?.put(path: candidate.file.path,
                   mtime: candidate.mtime,
                   size: candidate.size,
                   summary: persisted)

        return Conversation(persisted: persisted, sessionFile: candidate.file)
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
            state: .dormant
        )
    }
}
