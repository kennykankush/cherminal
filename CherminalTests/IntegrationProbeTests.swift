import Testing
import Foundation
import Darwin
@testable import Cherminal

/// Integration probes: these exercise the REAL system pipelines (lsof over a
/// live Unix socket; FSEvents through the watcher) rather than parsers over
/// fixtures — the part of the probe stack that unit tests can't vouch for.
struct ProcTableIntegrationTests {

    /// Bind a real Unix socket from THIS process and verify the full
    /// lsof -U → parse → holders pipeline reports us — the exact mechanism
    /// dtach-master liveness rides on (macOS pgrep is blind to daemonized
    /// masters; lsof on the socket is the load-bearing workaround).
    @Test func captureSeesARealUnixSocketHolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-sock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("itest.sock").path
        try #require(path.utf8.count < 100, "unix socket paths cap at ~104 bytes")

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd); unlink(path) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let copied: Bool = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let capacity = MemoryLayout.size(ofValue: ptr.pointee)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= capacity else { return false }
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
            return true
        }
        try #require(copied)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)

        let table = try #require(ProcTable.capture(socketDir: dir))
        let me = getpid()
        #expect(table.holders(ofSocket: path).contains(me))
        // The ps half of the snapshot must know us too.
        #expect(table.argv[me] != nil)
        #expect(table.parent[me] != nil)
        // And the liveness answer built on it.
        #expect(!table.holders(ofSocket: dir.appendingPathComponent("absent.sock").path)
            .contains(me))
    }
}

struct FilesystemWatcherIntegrationTests {

    private final class DeliveryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveries: [(at: Date, paths: [String])] = []
        func record(_ paths: [String]) {
            lock.lock(); deliveries.append((Date(), paths)); lock.unlock()
        }
        func all() -> [(at: Date, paths: [String])] {
            lock.lock(); defer { lock.unlock() }; return deliveries
        }
        func containsPath(_ path: String) -> Bool {
            all().contains { $0.paths.contains(path) }
        }
    }

    /// A single write must arrive as a changed-path delivery, and a CONTINUOUS
    /// write burst must still deliver within the max-latency bound — the
    /// guarantee that a long agent turn can't starve the registry/turn-light
    /// (the old trailing-only debounce re-armed forever). Generous timing
    /// margins: CI file systems are slow, and this asserts ordering guarantees,
    /// not exact latencies.
    @Test func deliversPathsAndHonorsMaxLatencyUnderBurst() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let box = DeliveryBox()
        let watcher = FilesystemWatcher(paths: [dir.path], debounce: 0.15, maxLatency: 0.8) { paths in
            box.record(paths)
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(400))   // FSEvents stream warm-up

        // One write → one delivery carrying that path.
        let file = dir.appendingPathComponent("a.jsonl")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        var sawSingle = false
        for _ in 0..<40 where !sawSingle {   // ≤4s
            try await Task.sleep(for: .milliseconds(100))
            // FSEvents may report the realpath (/private/var/…) — match by suffix.
            sawSingle = box.all().contains { $0.paths.contains { $0.hasSuffix("/a.jsonl") } }
        }
        #expect(sawSingle, "a single write should be delivered with its path")

        // Continuous burst: writes every 100ms for 2s would re-arm a pure
        // trailing debounce forever; max-latency (0.8s) must force deliveries
        // DURING the burst.
        let before = box.all().count
        let burstStart = Date()
        while Date().timeIntervalSince(burstStart) < 2.0 {
            try? "y\n".write(to: dir.appendingPathComponent("b.jsonl"),
                             atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(100))
        }
        let during = box.all().filter {
            $0.at > burstStart && $0.at.timeIntervalSince(burstStart) < 2.0
        }.count
        _ = before
        #expect(during >= 1, "max-latency must force at least one mid-burst delivery")
    }
}
