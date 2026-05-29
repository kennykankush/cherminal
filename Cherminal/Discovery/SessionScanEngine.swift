import Foundation

/// One session file an agent scanner found on disk, before parsing.
struct ScanCandidate: Sendable {
    let file: URL
    let mtime: Double
    let size: Int64
    /// Best-guess room path from the directory layout (Claude's encoded folder
    /// name). nil when the source has no such hint (Codex reads cwd from the
    /// file instead). Parsers prefer the in-file cwd; this is the fallback.
    let roomHint: String?
}

/// The shared scan machinery every agent source runs through: stat → classify
/// cache hit vs miss → emit hits immediately → parse misses with bounded
/// concurrency → emit each as it lands → finish with the full live set.
///
/// Only the per-agent bits differ (where files live, how one file is parsed),
/// so a source supplies just `prepare`/`enumerate`/`parse`. Adding a third
/// agent is a ~40-line file, not a copy of this whole pipeline.
enum SessionScanEngine {
    static let concurrencyLimit = 8

    enum Update: Sendable {
        case cacheHits([Conversation])
        case parsed(Conversation)
        case finished(conversations: [Conversation], livePaths: Set<String>)
    }

    /// `Prep` is an agent-specific context computed once per scan (e.g. Codex's
    /// title index) and handed to every `parse` call. Use `Void` when unneeded.
    static func stream<Prep: Sendable>(
        cache: SessionCache?,
        prepare: @escaping @Sendable () -> Prep,
        enumerate: @escaping @Sendable (Prep) -> [ScanCandidate],
        parse: @escaping @Sendable (ScanCandidate, Prep) -> Conversation?
    ) -> AsyncStream<Update> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task.detached(priority: .utility) {
                let prep = prepare()
                let candidates = enumerate(prep)

                // Pass 1 — classify hit vs miss off a single stat each.
                var hits: [Conversation] = []
                var misses: [ScanCandidate] = []
                for c in candidates {
                    if let cache,
                       let entry = cache.get(path: c.file.path, mtime: c.mtime, size: c.size),
                       let convo = Conversation(persisted: entry.summary, sessionFile: c.file) {
                        hits.append(convo)
                    } else {
                        misses.append(c)
                    }
                }
                if !hits.isEmpty {
                    continuation.yield(.cacheHits(hits.sorted { $0.lastActivityAt > $1.lastActivityAt }))
                }

                // Pass 2 — parse misses concurrently, emitting each as it lands.
                // Wrap the parse phase's cache writes in one transaction so the
                // per-miss puts collapse into a single WAL flush instead of one
                // commit per file.
                var parsed: [Conversation] = []
                if !misses.isEmpty {
                    cache?.beginBatch()
                    parsed = await withTaskGroup(of: Conversation?.self) { group in
                        var collected: [Conversation] = []
                        var it = misses.makeIterator()
                        for _ in 0..<concurrencyLimit {
                            guard let next = it.next() else { break }
                            group.addTask { parse(next, prep) }
                        }
                        while let result = await group.next() {
                            if let convo = result {
                                collected.append(convo)
                                continuation.yield(.parsed(convo))
                            }
                            if let next = it.next() { group.addTask { parse(next, prep) } }
                        }
                        return collected
                    }
                    cache?.endBatch()
                }

                // Reconcile (dropping rows neither source saw) is the registry's
                // job — it owns the union of all sources' live sets.
                let live = Set(candidates.map { $0.file.path })
                let merged = (hits + parsed).sorted { $0.lastActivityAt > $1.lastActivityAt }
                continuation.yield(.finished(conversations: merged, livePaths: live))
                continuation.finish()
            }
        }
    }
}
