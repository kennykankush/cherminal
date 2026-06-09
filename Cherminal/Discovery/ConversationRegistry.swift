import Foundation
import Combine
import os

/// Source of truth for the conversations the sidebar renders.
///
/// Lifecycle:
///   • init builds the SQLite cache (falling back to no-cache on failure
///     so an unwritable disk never breaks the UI).
///   • `bootstrap()` runs once per app launch: publishes the cached
///     snapshot immediately, then runs the scanner in the background and
///     pushes deltas as they arrive. After the first scan finishes it
///     spins up the FilesystemWatcher so future Claude Code writes flow
///     through the same incremental update path.
///   • `refresh()` is reentrant — the watcher uses it, and so does any
///     manual sidebar refresh.
@MainActor
final class ConversationRegistry: ObservableObject {
    private static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "registry")

    @Published private(set) var conversations: [Conversation] = [] {
        didSet { rebuildRooms() }
    }
    /// Derived grouping, recomputed only when `conversations` changes — not on
    /// every render or port-scan tick (both used to call the old computed var).
    @Published private(set) var rooms: [Room] = []
    /// Sessions that have been superseded by a post-compaction continuation —
    /// i.e. some other conversation lists them as its `continuedFromID`. The
    /// sidebar dims + badges these so a compaction reads as one chain, not two
    /// mysterious duplicates. Recomputed with `rooms` when conversations change.
    @Published private(set) var supersededIDs: Set<String> = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    let cache: SessionCache?
    private var watcher: FilesystemWatcher?
    private var didBootstrap = false
    private var didLoadCache = false
    private var refreshInFlight: Task<Void, Never>?
    /// Set when refresh() is called while a scan is already running, so the
    /// loop runs once more and never drops a change that arrived mid-scan.
    private var pendingRefresh = false

    init(cache: SessionCache? = nil) {
        if let cache {
            self.cache = cache
        } else {
            do {
                self.cache = try SessionCache()
            } catch {
                Self.logger.error("cache init failed: \(error.localizedDescription, privacy: .public)")
                self.cache = nil
            }
        }
    }

    // MARK: - Public API

    /// Publish whatever the cache has so the sidebar — and session restore —
    /// see real conversations (with correct `sessionFile`s) without waiting on
    /// the disk scan. The load + JSON-decode of every row runs off the main
    /// actor so it doesn't block first paint when there are hundreds of rows.
    /// Idempotent; the slow reconcile lives in `bootstrap()`.
    func loadCacheSnapshot() async {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let cache else { return }
        let snapshot = await Task.detached(priority: .userInitiated) {
            cache.loadAll().compactMap { entry in
                Conversation(persisted: entry.summary,
                             sessionFile: URL(fileURLWithPath: entry.path))
            }.sorted { $0.lastActivityAt > $1.lastActivityAt }
        }.value
        if !snapshot.isEmpty {
            conversations = snapshot
        }
    }

    /// Called once per app launch from the root view's `.task`. Idempotent.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // 1. Cache snapshot for instant render (no-op if already loaded by the
        //    launch path for session restore).
        await loadCacheSnapshot()

        // 2. Run a fresh scan to reconcile against disk.
        await refresh()

        // 3. Start the watcher so future changes flow back through refresh.
        startWatcher()
    }

    /// Reconcile the in-memory conversation list against `~/.claude/projects/`.
    /// Cache hits land immediately, misses parse in the background and arrive
    /// over the AsyncStream. Multiple concurrent refresh calls coalesce — the
    /// in-flight task is reused.
    func refresh() async {
        if let inflight = refreshInFlight {
            // A change landed mid-scan — the in-flight pass may have already
            // walked past it, so flag one more run after it completes.
            pendingRefresh = true
            await inflight.value
            return
        }

        repeat {
            pendingRefresh = false
            let task = Task { await runScan() }
            refreshInFlight = task
            await task.value
            refreshInFlight = nil
        } while pendingRefresh
    }

    func conversation(id: Conversation.ID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    // MARK: - Incremental refresh (the watcher's changed paths)

    /// Refresh only what changed. A write to one session used to trigger a
    /// FULL stat-sweep of every session on disk (the 18%-CPU incident was
    /// "fixed" by lowering the frequency, not the work); FSEvents hands us the
    /// changed paths, so the standing cost is now O(changed). Any non-session
    /// path in the batch (a directory, a watched root on FSEvents overflow)
    /// falls back to the authoritative full scan.
    func refresh(changedPaths: [String]) async {
        let home = NSHomeDirectory()
        let claudeRoot = home + "/.claude/projects/"
        let codexRoot = home + "/.codex/sessions/"
        let files = changedPaths.filter {
            $0.hasSuffix(".jsonl") && ($0.hasPrefix(claudeRoot) || $0.hasPrefix(codexRoot))
        }
        guard files.count == changedPaths.count, !files.isEmpty else {
            await refresh()
            return
        }
        // A full scan is already running — it stats everything, so it will see
        // these changes; just make sure one more pass follows it.
        if refreshInFlight != nil {
            pendingRefresh = true
            return
        }
        let task = Task { await applyChangedFiles(files, claudeRoot: claudeRoot) }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
        if pendingRefresh { await refresh() }
    }

    /// Parse the changed files off-main, then merge into the published list.
    private func applyChangedFiles(_ paths: [String], claudeRoot: String) async {
        let cache = self.cache
        let result = await Task.detached(priority: .utility) {
            () -> (parsed: [Conversation], removed: [String]) in
            var parsed: [Conversation] = []
            var removed: [String] = []
            lazy var titles = CodexSessionScanner.titleIndex()
            for path in paths {
                guard FileManager.default.fileExists(atPath: path) else {
                    removed.append(path)
                    cache?.remove(path: path)
                    continue
                }
                let url = URL(fileURLWithPath: path)
                let convo = path.hasPrefix(claudeRoot)
                    ? ClaudeSessionScanner.summarizeFile(url, cache: cache)
                    : CodexSessionScanner.summarizeFile(url, titles: titles, cache: cache)
                if let convo { parsed.append(convo) }
            }
            return (parsed, removed)
        }.value
        guard !(result.parsed.isEmpty && result.removed.isEmpty) else { return }

        // Merge, honoring the id-collision rule the full scan uses: two files
        // can share one session id (codex forks a rollout on resume) and the
        // most recently active one owns the id.
        var byID = Dictionary(
            conversations.map { ($0.id, $0) },
            uniquingKeysWith: { $0.lastActivityAt >= $1.lastActivityAt ? $0 : $1 }
        )
        if !result.removed.isEmpty {
            let removedSet = Set(result.removed)
            byID = byID.filter { !removedSet.contains($0.value.sessionFile.path) }
        }
        for convo in result.parsed {
            if let existing = byID[convo.id],
               existing.sessionFile.path != convo.sessionFile.path,
               existing.lastActivityAt > convo.lastActivityAt {
                continue   // a newer file already owns this id (fork rule)
            }
            byID[convo.id] = convo
        }
        publish(from: byID)
    }

    private func rebuildRooms() {
        let grouped = Dictionary(grouping: conversations, by: \.roomPath)
        rooms = grouped
            .map {
                Room(id: $0.key.path,
                     path: $0.key,
                     conversations: $0.value.sorted { $0.lastActivityAt > $1.lastActivityAt })
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        // A session is superseded when another lists it as its parent.
        supersededIDs = Set(conversations.compactMap(\.continuedFromID))
    }

    // MARK: - Scanner

    private func runScan() async {
        clog("scan", "start (had \(conversations.count) conversations)")
        isLoading = true
        defer {
            isLoading = false
            clog("scan", "finished — \(conversations.count) conversations")
        }

        // Run every agent source concurrently through the shared engine. Each
        // emits over its own AsyncStream; we round-robin the iterators and
        // publish after every update so the sidebar fills in incrementally as
        // either source's parses complete.
        // Tolerate duplicate ids: Codex can emit two rollout files with the SAME
        // session id (a fork/resume, or a session bridged across runtimes), so two
        // conversations legitimately share an id. `uniqueKeysWithValues` TRAPS on a
        // dup → crash-on-launch — never use it for agent-derived ids we don't
        // control. Keep the most recently active on collision.
        var staged: [String: Conversation] = Dictionary(
            conversations.map { ($0.id, $0) },
            uniquingKeysWith: { $0.lastActivityAt >= $1.lastActivityAt ? $0 : $1 }
        )
        var live: Set<String> = []

        var iterators = [
            ClaudeSessionScanner(cache: cache).scan().makeAsyncIterator(),
            CodexSessionScanner(cache: cache).scan().makeAsyncIterator(),
        ]
        var open = Array(repeating: true, count: iterators.count)

        while open.contains(true) {
            for i in iterators.indices where open[i] {
                if let update = await iterators[i].next() {
                    apply(update, staged: &staged, live: &live)
                } else {
                    open[i] = false
                }
            }
        }

        // Authoritative reconciliation: drop staged entries (and cache rows)
        // that no source saw on this pass. This has to live HERE, not inside a
        // source — each source only knows its own live set, so a per-source
        // reconcile would clobber the others' rows.
        staged = staged.filter { _, convo in live.contains(convo.sessionFile.path) }
        cache?.reconcile(keepingPaths: live)
        publish(from: staged)
    }

    /// Publish budget — at most one publish per `publishThrottle` seconds
    /// while parses are streaming in. Cache hits and "finished" always
    /// publish immediately because they're meaningful checkpoints.
    private static let publishThrottle: TimeInterval = 0.1
    private var lastPublishAt: Date = .distantPast

    private func apply(
        _ update: SessionScanEngine.Update,
        staged: inout [String: Conversation],
        live: inout Set<String>
    ) {
        switch update {
        case .cacheHits(let hits):
            for hit in hits {
                staged[hit.id] = hit
                live.insert(hit.sessionFile.path)
            }
            publish(from: staged)
        case .parsed(let convo):
            staged[convo.id] = convo
            live.insert(convo.sessionFile.path)
            throttledPublish(from: staged)
        case .finished(let conversations, let livePaths):
            for convo in conversations { staged[convo.id] = convo }
            live.formUnion(livePaths)
            publish(from: staged)
        }
    }

    private func throttledPublish(from staged: [String: Conversation]) {
        let now = Date()
        guard now.timeIntervalSince(lastPublishAt) >= Self.publishThrottle else { return }
        lastPublishAt = now
        publish(from: staged)
    }

    private func publish(from staged: [String: Conversation]) {
        conversations = Array(staged.values).sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    // MARK: - Watcher

    private func startWatcher() {
        guard watcher == nil else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let paths = [
            home.appendingPathComponent(".claude/projects", isDirectory: true).path,
            home.appendingPathComponent(".codex/sessions", isDirectory: true).path,
        ].filter { FileManager.default.fileExists(atPath: $0) }

        guard !paths.isEmpty else { return }

        // 2.5s coalescing batches an agent turn's write-burst into one fire;
        // each fire is now an INCREMENTAL refresh of just the changed files
        // (refresh(changedPaths:)), not a full re-scan of every session — the
        // old full-scan-per-fire burned ~18% CPU under an active agent. The
        // watcher's max-latency bound guarantees a fire at least every ~10s
        // even mid-burst, so a long continuous turn can't starve the sidebar.
        let watcher = FilesystemWatcher(paths: paths, debounce: 2.5) { [weak self] changed in
            // FSEvents callback fires on a background queue; hop to main
            // before touching @Published state.
            Task { @MainActor [weak self] in
                await self?.refresh(changedPaths: changed)
            }
        }
        watcher.start()
        self.watcher = watcher
    }
}
