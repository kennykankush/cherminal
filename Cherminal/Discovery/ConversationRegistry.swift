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
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    let cache: SessionCache?
    private var watcher: FilesystemWatcher?
    private var didBootstrap = false
    private var refreshInFlight: Task<Void, Never>?

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

    /// Called once per app launch from the root view's `.task`. Idempotent.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // 1. Publish whatever the cache has so the sidebar renders instantly.
        if let cache {
            let snapshot = cache.loadAll().compactMap { entry in
                Conversation(persisted: entry.summary,
                             sessionFile: URL(fileURLWithPath: entry.path))
            }.sorted { $0.lastActivityAt > $1.lastActivityAt }
            if !snapshot.isEmpty {
                conversations = snapshot
            }
        }

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
            await inflight.value
            return
        }

        let task = Task { await runScan() }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
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
    }

    // MARK: - Scanner

    private func runScan() async {
        clog("scan", "start (had \(conversations.count) conversations)")
        isLoading = true
        defer {
            isLoading = false
            clog("scan", "finished — \(conversations.count) conversations")
        }

        // Run Claude and Codex scanners concurrently. Each emits over its
        // own AsyncStream; we round-robin between the two iterators and
        // publish after every update so the sidebar fills in incrementally
        // as either agent's parses complete.
        var staged: [String: Conversation] = Dictionary(
            uniqueKeysWithValues: conversations.map { ($0.id, $0) }
        )
        var claudeLive: Set<String> = []
        var codexLive: Set<String> = []

        let claudeScanner = ClaudeSessionScanner(cache: cache)
        let codexScanner = CodexSessionScanner(cache: cache)
        var claudeIter = claudeScanner.scan().makeAsyncIterator()
        var codexIter = codexScanner.scan().makeAsyncIterator()
        var claudeOpen = true
        var codexOpen = true

        while claudeOpen || codexOpen {
            if claudeOpen {
                if let update = await claudeIter.next() {
                    apply(claude: update, staged: &staged, claudeLive: &claudeLive)
                } else {
                    claudeOpen = false
                }
            }
            if codexOpen {
                if let update = await codexIter.next() {
                    apply(codex: update, staged: &staged, codexLive: &codexLive)
                } else {
                    codexOpen = false
                }
            }
        }

        // Authoritative reconciliation: drop staged entries (and cache
        // rows) that neither scanner saw on this pass. The cache reconcile
        // has to live HERE, not inside individual scanners — each scanner
        // only knows its own live set, so a per-scanner reconcile would
        // clobber the other agent's rows.
        let live = claudeLive.union(codexLive)
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
        claude update: ClaudeSessionScanner.Update,
        staged: inout [String: Conversation],
        claudeLive: inout Set<String>
    ) {
        switch update {
        case .cacheHits(let hits):
            for hit in hits {
                staged[hit.id] = hit
                claudeLive.insert(hit.sessionFile.path)
            }
            publish(from: staged)
        case .parsed(let convo):
            staged[convo.id] = convo
            claudeLive.insert(convo.sessionFile.path)
            throttledPublish(from: staged)
        case .finished(let result):
            for convo in result.conversations { staged[convo.id] = convo }
            claudeLive.formUnion(result.livePaths)
            publish(from: staged)
        }
    }

    private func apply(
        codex update: CodexSessionScanner.Update,
        staged: inout [String: Conversation],
        codexLive: inout Set<String>
    ) {
        switch update {
        case .cacheHits(let hits):
            for hit in hits {
                staged[hit.id] = hit
                codexLive.insert(hit.sessionFile.path)
            }
            publish(from: staged)
        case .parsed(let convo):
            staged[convo.id] = convo
            codexLive.insert(convo.sessionFile.path)
            throttledPublish(from: staged)
        case .finished(let livePaths):
            codexLive.formUnion(livePaths)
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

        let watcher = FilesystemWatcher(paths: paths) { [weak self] in
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
