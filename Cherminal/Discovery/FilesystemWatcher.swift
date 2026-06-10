import CoreServices
import Foundation
import os

/// Watches one or more directory trees and fans CHANGED PATHS out to any
/// number of subscribers, each with its OWN debounce + max-latency cadence —
/// one kernel FSEventStream serves them all. (The registry coalesces at 2.5s
/// for sidebar refreshes while the coordinator wants ~0.3s for the "your
/// turn" light; they used to run two separate streams over the same roots.)
///
/// FSEvents is used (not DispatchSource on a directory FD) so line-by-line
/// writes into nested session files are caught. Per-subscriber coalescing is
/// trailing-debounce PLUS a max-latency bound: a trailing debounce alone can
/// be starved forever by continuous writes (each event re-arms it), so once
/// the oldest pending change is older than `maxLatency`, delivery happens
/// even mid-burst.
///
/// Delivered paths may include directories (or the watched roots) when
/// FSEvents signals a sub-directory scan (event overflow); consumers should
/// treat any non-file path as "rescan everything".
final class FilesystemWatcher {
    private static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "watcher")
    /// Kernel-side coalescing window. Small and fixed — real cadence shaping
    /// is per-subscriber, so the fastest subscriber sets the floor here.
    private static let kernelLatency: TimeInterval = 0.25

    private let paths: [String]
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    /// One consumer's cadence + pending state. All access on `queue`.
    private final class Subscriber {
        let debounce: TimeInterval
        let maxLatency: TimeInterval
        let onChange: @Sendable ([String]) -> Void
        var pendingPaths: Set<String> = []
        var firstPendingAt: Date?
        var debounceItem: DispatchWorkItem?

        init(debounce: TimeInterval, maxLatency: TimeInterval?,
             onChange: @escaping @Sendable ([String]) -> Void) {
            self.debounce = debounce
            // Default: a burst may delay delivery to at most 4× the debounce.
            self.maxLatency = maxLatency ?? max(debounce * 4, 1.0)
            self.onChange = onChange
        }
    }

    private var subscribers: [UUID: Subscriber] = [:]

    init(paths: [String]) {
        self.paths = paths
        self.queue = DispatchQueue(label: "dev.hamulia.Cherminal.fswatcher", qos: .utility)
    }

    /// Single-consumer convenience — init + subscribe in one step (the
    /// standalone uses and the integration tests).
    convenience init(
        paths: [String],
        debounce: TimeInterval = 0.3,
        maxLatency: TimeInterval? = nil,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.init(paths: paths)
        _ = subscribe(debounce: debounce, maxLatency: maxLatency, onChange: onChange)
    }

    deinit { stop() }

    // MARK: - Subscriptions

    /// Add a consumer with its own cadence. Returns a token for unsubscribe.
    /// The kernel stream itself starts/stops via start()/stop().
    @discardableResult
    func subscribe(
        debounce: TimeInterval,
        maxLatency: TimeInterval? = nil,
        onChange: @escaping @Sendable ([String]) -> Void
    ) -> UUID {
        let id = UUID()
        let sub = Subscriber(debounce: debounce, maxLatency: maxLatency, onChange: onChange)
        queue.async { [weak self] in self?.subscribers[id] = sub }
        return id
    }

    func unsubscribe(_ id: UUID) {
        queue.async { [weak self] in
            guard let self, let sub = self.subscribers.removeValue(forKey: id) else { return }
            sub.debounceItem?.cancel()
        }
    }

    // MARK: - Kernel stream

    func start() {
        guard stream == nil else { return }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: UInt32 = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        let stream = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FilesystemWatcher>.fromOpaque(info).takeUnretainedValue()
                // With UseCFTypes the paths argument is a CFArray of CFString.
                let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
                var changed: [String] = []
                for i in 0..<numEvents where i < cfPaths.count {
                    // An overflowed event means "everything under this dir may
                    // have changed" — deliver the dir itself; consumers treat a
                    // non-file path as a full-rescan signal.
                    changed.append(cfPaths[i])
                    if (eventFlags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0 {
                        FilesystemWatcher.logger.warning("FSEvents overflow under \(cfPaths[i], privacy: .public)")
                    }
                }
                watcher.fanOut(paths: changed)
            },
            &context,
            paths as CFArray,
            UInt64(kFSEventStreamEventIdSinceNow),
            Self.kernelLatency,
            flags
        )

        guard let stream else {
            Self.logger.error("FSEventStreamCreate failed")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        queue.async { [weak self] in
            guard let self else { return }
            for sub in self.subscribers.values {
                sub.debounceItem?.cancel()
                sub.debounceItem = nil
                sub.pendingPaths = []
                sub.firstPendingAt = nil
            }
        }
    }

    // MARK: - Per-subscriber debounce (trailing edge + max-latency bound)

    private func fanOut(paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            for sub in self.subscribers.values {
                self.schedule(paths: paths, for: sub)
            }
        }
    }

    /// Runs on `queue`.
    private func schedule(paths: [String], for sub: Subscriber) {
        sub.pendingPaths.formUnion(paths)
        if sub.firstPendingAt == nil { sub.firstPendingAt = Date() }

        // Max-latency: continuous writes re-arm a trailing debounce forever
        // (FSEvents delivers ~every kernel-latency tick, each delivery
        // cancelling the pending fire). If the oldest undelivered change has
        // waited long enough, deliver NOW instead of re-arming.
        if let first = sub.firstPendingAt,
           Date().timeIntervalSince(first) >= sub.maxLatency {
            sub.debounceItem?.cancel()
            sub.debounceItem = nil
            deliver(sub)
            return
        }

        sub.debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak sub] in
            guard let self, let sub else { return }
            self.deliver(sub)
        }
        sub.debounceItem = item
        queue.asyncAfter(deadline: .now() + sub.debounce, execute: item)
    }

    /// Runs on `queue`.
    private func deliver(_ sub: Subscriber) {
        let paths = Array(sub.pendingPaths)
        sub.pendingPaths = []
        sub.firstPendingAt = nil
        guard !paths.isEmpty else { return }
        sub.onChange(paths)
    }
}
