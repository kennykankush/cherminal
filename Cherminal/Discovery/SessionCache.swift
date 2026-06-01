import Foundation
import SQLite3
import os

/// Persistent on-disk cache for parsed conversation summaries, backed by SQLite.
///
/// Stored at `~/Library/Application Support/dev.hamulia.Cherminal/registry.sqlite`.
/// Keying is by absolute file path; cache hit requires `(mtime, size)` to match
/// the file on disk. Pin state for conversations lives in the same database.
///
/// Concurrency: SQLite is opened in WAL mode so a background scanner can write
/// while the UI reads cached rows on launch. All methods on this class are
/// safe to call from any thread — internal access is serialized by a lock.
final class SessionCache: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "cache")
    private static let schemaVersion: Int = 6

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let url: URL

    struct Entry {
        let path: String
        let mtime: Double
        let size: Int64
        let summary: PersistedSummary
    }

    /// What we store in the cache for each session file.
    struct PersistedSummary: Codable {
        var id: String
        var agentRaw: String
        var roomPath: String
        var firstTimestamp: Date?
        var lastTimestamp: Date
        var messageCount: Int
        var previewText: String?
    }

    convenience init() throws {
        try self.init(url: Self.databaseURL())
    }

    /// Designated init — `url` is injectable so tests can point at a temp DB
    /// instead of the app's shared registry.
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw CacheError.open(message)
        }

        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrateSchema()
    }

    deinit {
        sqlite3_finalize(putStmt)
        sqlite3_close(db)
    }

    /// Cached upsert statement — reused (reset+rebind) instead of recompiled on
    /// every `put`, which on a cold scan meant ~one prepare per session file.
    private var putStmt: OpaquePointer?

    // MARK: - Schema

    private func migrateSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS conversations (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                json TEXT NOT NULL,
                updated_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS pin_state (
                session_id TEXT PRIMARY KEY,
                pinned_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS bookmarks (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                tabs_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        // ADE (v6) user-data tables. Each stores the full Codable entity as a
        // JSON blob (load-all + decode + sort in the manager); a single small
        // upsert per change is plenty cheap. CREATE IF NOT EXISTS is idempotent
        // and these are user data — never added to the conversations DELETE.
        try exec("CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, json TEXT NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS swarm_templates (id TEXT PRIMARY KEY, json TEXT NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS kanban_columns (id TEXT PRIMARY KEY, json TEXT NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS kanban_tasks (id TEXT PRIMARY KEY, json TEXT NOT NULL);")

        let currentVersion = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_version") ?? 0
        if currentVersion < Self.schemaVersion {
            // The conversations table is a pure derived cache — clear it on any
            // schema upgrade so rows are re-parsed with the latest logic (e.g.
            // the cwd-based room fix in v3). Pins / bookmarks / last_session
            // are user data and are preserved.
            try exec("DELETE FROM conversations;")
            try exec("INSERT OR REPLACE INTO schema_version (version) VALUES (\(Self.schemaVersion));")
        }
    }

    // MARK: - Conversation cache CRUD

    /// Returns the cached entry if `(path, mtime, size)` match. nil on miss
    /// or stale row. Stale rows are NOT auto-evicted here; callers do that
    /// via `remove` once they confirm the file is gone.
    func get(path: String, mtime: Double, size: Int64) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        let sql = "SELECT path, mtime, size, json FROM conversations WHERE path = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, path, -1, Self.sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let storedMtime = sqlite3_column_double(stmt, 1)
        let storedSize = sqlite3_column_int64(stmt, 2)
        guard storedMtime == mtime, storedSize == size else { return nil }

        guard let jsonPtr = sqlite3_column_text(stmt, 3) else { return nil }
        let json = String(cString: jsonPtr)
        guard let summary = decode(json: json) else { return nil }

        return Entry(path: path, mtime: storedMtime, size: storedSize, summary: summary)
    }

    /// Read every row regardless of file-system state. Used at launch for the
    /// instant snapshot; the scanner reconciles against disk afterward.
    func loadAll() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        var out: [Entry] = []
        let sql = "SELECT path, mtime, size, json FROM conversations;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let mtime = sqlite3_column_double(stmt, 1)
            let size = sqlite3_column_int64(stmt, 2)
            guard let jsonPtr = sqlite3_column_text(stmt, 3) else { continue }
            let json = String(cString: jsonPtr)
            guard let summary = decode(json: json) else { continue }
            out.append(Entry(path: path, mtime: mtime, size: size, summary: summary))
        }
        return out
    }

    func put(path: String, mtime: Double, size: Int64, summary: PersistedSummary) {
        guard let json = encode(summary: summary) else { return }
        lock.lock(); defer { lock.unlock() }

        // Prepare once, then reuse with reset+clear_bindings on every call.
        if putStmt == nil {
            let sql = """
                INSERT INTO conversations (path, mtime, size, json, updated_at)
                VALUES (?, ?, ?, ?, strftime('%s', 'now'))
                ON CONFLICT(path) DO UPDATE SET
                    mtime = excluded.mtime,
                    size = excluded.size,
                    json = excluded.json,
                    updated_at = excluded.updated_at;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &putStmt, nil) == SQLITE_OK else {
                Self.logger.error("put prepare failed: \(self.lastError(), privacy: .public)")
                putStmt = nil
                return
            }
        }
        let stmt = putStmt
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, path, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 2, mtime)
        sqlite3_bind_int64(stmt, 3, size)
        sqlite3_bind_text(stmt, 4, json, -1, Self.sqliteTransient)
        if sqlite3_step(stmt) != SQLITE_DONE {
            Self.logger.error("put step failed: \(self.lastError(), privacy: .public)")
        }
    }

    /// Nesting depth of active batches. The Claude and Codex scanners share one
    /// connection and run concurrently, so their begin/endBatch calls interleave
    /// — a depth counter (BEGIN on 0→1, COMMIT on 1→0) keeps the early
    /// `endBatch` of one scanner from committing the other's in-flight rows.
    private var batchDepth = 0

    /// Wrap a burst of `put`s (a scan's parse phase) in one transaction so ~N
    /// per-row WAL commits collapse into a single flush.
    func beginBatch() {
        lock.lock(); defer { lock.unlock() }
        batchDepth += 1
        if batchDepth == 1 && sqlite3_get_autocommit(db) != 0 {
            sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        }
    }

    func endBatch() {
        lock.lock(); defer { lock.unlock() }
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        if batchDepth == 0 && sqlite3_get_autocommit(db) == 0 {
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    func remove(path: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "DELETE FROM conversations WHERE path = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    /// Batch-remove paths that no longer exist on disk. Called by the scanner
    /// after a full pass so the cache stays tight.
    func reconcile(keepingPaths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var read: OpaquePointer?
        defer { sqlite3_finalize(read) }
        guard sqlite3_prepare_v2(db, "SELECT path FROM conversations;", -1, &read, nil) == SQLITE_OK else { return }
        var stalePaths: [String] = []
        while sqlite3_step(read) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(read, 0))
            if !keepingPaths.contains(path) {
                stalePaths.append(path)
            }
        }
        guard !stalePaths.isEmpty else { return }
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        var del: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM conversations WHERE path = ?;", -1, &del, nil)
        for path in stalePaths {
            sqlite3_bind_text(del, 1, path, -1, Self.sqliteTransient)
            sqlite3_step(del)
            sqlite3_reset(del)
        }
        sqlite3_finalize(del)
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    // MARK: - Pin state

    func pinnedSessionIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT session_id FROM pin_state;", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    func setPinned(_ sessionID: String, pinned: Bool) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = pinned
            ? "INSERT OR IGNORE INTO pin_state (session_id) VALUES (?);"
            : "DELETE FROM pin_state WHERE session_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, sessionID, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    // MARK: - Bookmarks

    func loadBookmarks() -> [Bookmark] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, name, tabs_json, created_at, updated_at FROM bookmarks ORDER BY updated_at DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var out: [Bookmark] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            guard let id = UUID(uuidString: idStr) else { continue }
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let json = String(cString: sqlite3_column_text(stmt, 2))
            guard let data = json.data(using: .utf8),
                  let tabs = try? jsonDecoder.decode([PersistedTab].self, from: data) else { continue }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            out.append(Bookmark(id: id, name: name, tabs: tabs, createdAt: createdAt, updatedAt: updatedAt))
        }
        return out
    }

    func saveBookmark(_ bookmark: Bookmark) {
        guard let data = try? jsonEncoder.encode(bookmark.tabs),
              let json = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT INTO bookmarks (id, name, tabs_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                tabs_json = excluded.tabs_json,
                updated_at = excluded.updated_at;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, bookmark.id.uuidString, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, bookmark.name, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, json, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 4, bookmark.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, bookmark.updatedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func deleteBookmark(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM bookmarks WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    // MARK: - ADE entities (workspaces / swarm templates / kanban)

    func loadWorkspaces() -> [PersistedWorkspace] {
        loadJSONRows(table: "workspaces").compactMap(decodeEntity).sorted { $0.updatedAt > $1.updatedAt }
    }
    func saveWorkspace(_ w: PersistedWorkspace) { upsertEntity(table: "workspaces", id: w.id.uuidString, w) }
    func deleteWorkspace(id: UUID) { deleteRow(table: "workspaces", id: id.uuidString) }

    func loadSwarmTemplates() -> [SwarmTemplate] {
        loadJSONRows(table: "swarm_templates").compactMap(decodeEntity).sorted { $0.updatedAt > $1.updatedAt }
    }
    func saveSwarmTemplate(_ t: SwarmTemplate) { upsertEntity(table: "swarm_templates", id: t.id.uuidString, t) }
    func deleteSwarmTemplate(id: UUID) { deleteRow(table: "swarm_templates", id: id.uuidString) }

    func loadKanbanColumns() -> [KanbanColumn] {
        loadJSONRows(table: "kanban_columns").compactMap(decodeEntity).sorted { $0.order < $1.order }
    }
    func saveKanbanColumn(_ c: KanbanColumn) { upsertEntity(table: "kanban_columns", id: c.id.uuidString, c) }
    func deleteKanbanColumn(id: UUID) { deleteRow(table: "kanban_columns", id: id.uuidString) }

    func loadKanbanTasks() -> [KanbanTask] {
        loadJSONRows(table: "kanban_tasks").compactMap(decodeEntity).sorted { $0.order < $1.order }
    }
    func saveKanbanTask(_ t: KanbanTask) { upsertEntity(table: "kanban_tasks", id: t.id.uuidString, t) }
    func deleteKanbanTask(id: UUID) { deleteRow(table: "kanban_tasks", id: id.uuidString) }

    // MARK: - JSON-blob row helpers (table names are constants — safe to interpolate)

    private func loadJSONRows(table: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT json FROM \(table);", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) { out.append(String(cString: ptr)) }
        }
        return out
    }

    private func upsertEntity<T: Encodable>(table: String, id: String, _ value: T) {
        guard let data = try? jsonEncoder.encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO \(table) (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, id, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, json, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    private func deleteRow(table: String, id: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, id, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    private func decodeEntity<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(T.self, from: data)
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw CacheError.exec(message)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.exec(lastError())
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    }

    private static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Key the data dir off the running bundle id so a "Cherminal Dev"
        // debug build (dev.hamulia.Cherminal.dev) keeps its own cache and
        // never collides with the installed release app's data.
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.hamulia.Cherminal"
        return support
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("registry.sqlite", isDirectory: false)
    }

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func encode(summary: PersistedSummary) -> String? {
        guard let data = try? jsonEncoder.encode(summary) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decode(json: String) -> PersistedSummary? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(PersistedSummary.self, from: data)
    }

    enum CacheError: Error, CustomStringConvertible {
        case open(String)
        case exec(String)
        var description: String {
            switch self {
            case .open(let m): "sqlite open failed: \(m)"
            case .exec(let m): "sqlite exec failed: \(m)"
            }
        }
    }
}
