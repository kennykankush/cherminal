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
    private static let concurrencyLimit: Int = 8

    /// Final result of a complete scan pass. The registry diffs this against
    /// its current store and updates the UI.
    struct ScanResult: Sendable {
        let conversations: [Conversation]
        let livePaths: Set<String>
    }

    /// One incremental batch published by `scan`. Emitting hits separately
    /// from misses is what makes a warm-cache launch feel instant.
    enum Update: Sendable {
        case cacheHits([Conversation])
        case parsed(Conversation)
        case finished(ScanResult)
    }

    let cache: SessionCache?

    func scan() -> AsyncStream<Update> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task.detached(priority: .utility) {
                await self.run(into: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Run

    private func run(into continuation: AsyncStream<Update>.Continuation) async {
        let projectsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)

        let candidates = enumerateCandidates(under: projectsDir)
        var hits: [Conversation] = []
        var misses: [Candidate] = []

        // Pass 1 — stat each candidate, classify hit vs miss.
        for candidate in candidates {
            if let cache,
               let entry = cache.get(path: candidate.file.path,
                                     mtime: candidate.mtime,
                                     size: candidate.size),
               let convo = Conversation(persisted: entry.summary,
                                        sessionFile: candidate.file) {
                hits.append(convo)
            } else {
                misses.append(candidate)
            }
        }

        if !hits.isEmpty {
            continuation.yield(.cacheHits(hits.sorted { $0.lastActivityAt > $1.lastActivityAt }))
        }

        // Pass 2 — parse misses concurrently.
        var parsed: [Conversation] = []
        if !misses.isEmpty {
            parsed = await parseConcurrently(misses, continuation: continuation)
        }

        // Reconcile is the registry's job (it owns the union of all
        // scanners' live paths). Just report what we saw.
        let live = Set(candidates.map { $0.file.path })
        let merged = (hits + parsed).sorted { $0.lastActivityAt > $1.lastActivityAt }
        continuation.yield(.finished(ScanResult(conversations: merged, livePaths: live)))
    }

    // MARK: - Stat sweep

    private struct Candidate: Sendable {
        let file: URL
        let roomPath: URL
        let mtime: Double
        let size: Int64
    }

    private func enumerateCandidates(under projectsDir: URL) -> [Candidate] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Candidate] = []
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
                out.append(Candidate(file: file, roomPath: roomPath, mtime: mtime, size: size))
            }
        }
        return out
    }

    // MARK: - Parse pass

    private func parseConcurrently(
        _ candidates: [Candidate],
        continuation: AsyncStream<Update>.Continuation
    ) async -> [Conversation] {
        await withTaskGroup(of: Conversation?.self) { group in
            var collected: [Conversation] = []
            var iterator = candidates.makeIterator()

            // Prime the pump with concurrency-limit tasks.
            for _ in 0..<Self.concurrencyLimit {
                guard let next = iterator.next() else { break }
                group.addTask { Self.parseOne(next, cache: self.cache) }
            }

            // Drain + feed.
            while let result = await group.next() {
                if let convo = result {
                    collected.append(convo)
                    continuation.yield(.parsed(convo))
                }
                if let next = iterator.next() {
                    group.addTask { Self.parseOne(next, cache: self.cache) }
                }
            }
            return collected
        }
    }

    private static func parseOne(_ candidate: Candidate, cache: SessionCache?) -> Conversation? {
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
        let roomPath = summary.cwd ?? candidate.roomPath.path

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
