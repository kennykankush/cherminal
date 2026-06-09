import Foundation
import Darwin

/// Headless performance recorder. When enabled (`cherminal.metrics` default),
/// samples the process every few seconds and appends a row to
/// `~/.cherminal/metrics.csv` for offline graphing — RAM (phys_footprint, the
/// number Activity Monitor shows), CPU%, open FDs, thread count, thermal state,
/// plus app counts (tabs, live agents) and lifecycle counters (live windows /
/// surfaces — the leak tripwire: they should return to 0 when you close
/// everything). Off by default → zero standing cost in normal use.
///
/// All in-process (no sudo). For deep dives use the external tools:
///   leaks <pid> · vmmap/footprint <pid> · powermetrics (energy/thermal °C).

// MARK: - Lifecycle counters (leak tripwire)

/// Bump in `init`, drop in `deinit` of the heavy, leak-prone objects. If a
/// counter doesn't return to 0 after closing all tabs, that object is leaking
/// (a retained window / un-freed Metal surface). NSLock-guarded because deinit
/// of a @MainActor type is nonisolated and may run off-main.
enum LiveCount {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func inc(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    static func dec(_ key: String) { lock.lock(); counts[key, default: 0] -= 1; lock.unlock() }
    static func get(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
}

// MARK: - Raw process metrics (libproc, no sudo)

enum ProcMetrics {
    struct TaskSnapshot { var cpuTimeNs: UInt64; var threads: Int; var residentBytes: UInt64 }

    /// CPU time (user+system, ns), thread count, resident size — one syscall.
    static func task() -> TaskSnapshot {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &ti, size)
        guard rc == size else { return TaskSnapshot(cpuTimeNs: 0, threads: 0, residentBytes: 0) }
        return TaskSnapshot(
            cpuTimeNs: ti.pti_total_user + ti.pti_total_system,
            threads: Int(ti.pti_threadnum),
            residentBytes: ti.pti_resident_size
        )
    }

    /// Physical footprint in bytes — the real "Memory" number, the best leak signal.
    static func physFootprint() -> UInt64 {
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return rc == 0 ? usage.ri_phys_footprint : 0
    }

    /// Open file-descriptor count — climbing = an FD leak (a watcher / subprocess
    /// pipe that never closes). Passing a nil buffer returns the size needed.
    static func openFDCount() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return 0 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.size
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Recorder

@MainActor
final class MetricsRecorder {
    private weak var coordinator: TabWindowCoordinator?
    private var timer: Timer?
    private var lastCPUns: UInt64 = 0
    private var lastWallns: UInt64 = 0
    private let csvURL: URL
    private let writeQueue = DispatchQueue(label: "dev.hamulia.Cherminal.metrics", qos: .utility)
    private let interval: TimeInterval = 5

    init(coordinator: TabWindowCoordinator) {
        self.coordinator = coordinator
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".cherminal")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        csvURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("metrics.csv"))
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: "cherminal.metrics") }

    /// Begin sampling if the flag is on. Idempotent.
    func startIfEnabled() {
        guard enabled, timer == nil else { return }
        writeHeaderIfNeeded()
        let t = ProcMetrics.task()
        lastCPUns = t.cpuTimeNs
        lastWallns = DispatchTime.now().uptimeNanoseconds
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        clog("metrics", "recording every \(Int(interval))s → \(csvURL.path)")
        sample()   // baseline row now, so even a short session is captured
    }

    private func writeHeaderIfNeeded() {
        guard !FileManager.default.fileExists(atPath: csvURL.path) else { return }
        let header = "time,footprintMB,cpuPct,fds,threads,thermal,tabs,agents,windows,surfaces\n"
        try? header.write(to: csvURL, atomically: true, encoding: .utf8)
    }

    private func sample() {
        let task = ProcMetrics.task()
        let footprintMB = Double(ProcMetrics.physFootprint()) / 1_048_576.0
        let fds = ProcMetrics.openFDCount()

        // CPU% = Δcpu-time / Δwall-time × 100 (can exceed 100 across cores, like top).
        let now = DispatchTime.now().uptimeNanoseconds
        let cpuDelta = task.cpuTimeNs >= lastCPUns ? task.cpuTimeNs - lastCPUns : 0
        let wallDelta = now > lastWallns ? now - lastWallns : 1
        let cpuPct = Double(cpuDelta) / Double(wallDelta) * 100.0
        lastCPUns = task.cpuTimeNs
        lastWallns = now

        let tabs = coordinator?.tabCount ?? 0
        let agents = coordinator?.liveConversationIDs.count ?? 0
        let windows = LiveCount.get("window")
        // "pane" is the counter Pane.init/deinit actually bump. (This column
        // read the long-dead "holder" key after the TabSurfaceHolder→Pane
        // rename, so the surface-leak tripwire sat at a silent 0 — exactly the
        // instrumentation rot it exists to catch.)
        let surfaces = LiveCount.get("pane")

        let line = String(
            format: "%@,%.1f,%.1f,%d,%d,%@,%d,%d,%d,%d\n",
            Self.stamp(), footprintMB, cpuPct, fds, task.threads,
            ProcMetrics.thermal(), tabs, agents, windows, surfaces
        )
        let url = csvURL
        writeQueue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) { try? handle.write(contentsOf: data) }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static func stamp() -> String { formatter.string(from: Date()) }
}
