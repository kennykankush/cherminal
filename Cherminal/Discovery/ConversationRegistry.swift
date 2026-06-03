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
        var staged: [String: Conversation] = Dictionary(
            uniqueKeysWithValues: conversations.map { ($0.id, $0) }
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

        // Coalesce hard (2.5s vs the 0.3s default): each fire runs a FULL
        // re-scan of every session, and an active agent writing its JSONL emits
        // a continuous stream of FS events. At ~1000 conversations a 0.3s
        // debounce turned that into ~2 full scans/sec — each ending in a
        // main-thread @Published update + room rebuild + sidebar re-render —
        // which burned ~18% CPU and visibly lagged typing. The sidebar doesn't
        // need sub-second freshness; the "your turn"/live dots come from the
        // coordinator's own faster watcher, not this scan.
        let watcher = FilesystemWatcher(paths: paths, debounce: 2.5) { [weak self] in
            // FSEvents callback fires on a background queue; hop to main
            // before touching @Published state.
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        watcher.start()
        self.watcher = watcher
    }
}
