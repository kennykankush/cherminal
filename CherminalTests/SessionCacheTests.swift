import Testing
import Foundation
@testable import Cherminal

struct SessionCacheTests {
    private func tempCache() throws -> SessionCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SessionCache(url: dir.appendingPathComponent("registry.sqlite"))
    }

    private func summary(_ id: String) -> SessionCache.PersistedSummary {
        SessionCache.PersistedSummary(
            id: id, agentRaw: "claudeCode", roomPath: "/Users/x/dev/\(id)",
            firstTimestamp: nil, lastTimestamp: Date(timeIntervalSince1970: 1000),
            messageCount: 3, previewText: "hi \(id)")
    }

    @Test func putGetRoundTripWithMtimeSizeKeying() throws {
        let cache = try tempCache()
        cache.put(path: "/a.jsonl", mtime: 10, size: 100, summary: summary("a"))

        // Exact (path, mtime, size) hits.
        #expect(cache.get(path: "/a.jsonl", mtime: 10, size: 100)?.summary.id == "a")
        // Stale mtime or size misses.
        #expect(cache.get(path: "/a.jsonl", mtime: 11, size: 100) == nil)
        #expect(cache.get(path: "/a.jsonl", mtime: 10, size: 101) == nil)

        // Upsert via the cached statement: same path, new mtime, updated row.
        cache.put(path: "/a.jsonl", mtime: 11, size: 100, summary: summary("a2"))
        #expect(cache.get(path: "/a.jsonl", mtime: 11, size: 100)?.summary.id == "a2")
    }

    @Test func batchedPutsAllPersist() throws {
        let cache = try tempCache()
        cache.beginBatch()
        for i in 0..<50 {
            cache.put(path: "/f\(i).jsonl", mtime: Double(i), size: Int64(i), summary: summary("s\(i)"))
        }
        cache.endBatch()

        #expect(cache.loadAll().count == 50)
        #expect(cache.get(path: "/f7.jsonl", mtime: 7, size: 7)?.summary.id == "s7")
    }

    @Test func endBatchWithoutBeginIsSafe() throws {
        let cache = try tempCache()
        cache.endBatch()   // no open transaction — must be a no-op, not a crash
        cache.put(path: "/x.jsonl", mtime: 1, size: 1, summary: summary("x"))
        #expect(cache.get(path: "/x.jsonl", mtime: 1, size: 1) != nil)
    }
}
