import CoreServices
import Foundation
import os

/// Watches one or more directory trees and fires a callback with the CHANGED
/// PATHS whenever files underneath change. Backed by FSEvents so it catches
/// line-by-line writes into nested session files (DispatchSource on a
/// directory FD would only fire for the directory itself, not its descendants).
///
/// Coalescing happens twice: FSEvents `latency` batches kernel events, and a
/// Swift-side trailing debounce merges bursts — accumulating every reported
/// path — so a burst of writes during one agent turn yields ONE callback
/// carrying the union of paths. A trailing debounce alone can be starved
/// forever by continuous writes (each event re-arms it), so a MAX-LATENCY
/// bound guarantees delivery: once the oldest pending change is older than
/// `maxLatency`, the callback fires even mid-burst.
///
/// The callback's paths may include directories (or the watched roots) when
/// FSEvents signals a sub-directory scan (event overflow); consumers should
/// treat any non-file path as "rescan everything".
final class FilesystemWatcher {
    private static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "watcher")

    private let paths: [String]
    private let onChange: @Sendable ([String]) -> Void
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let maxLatency: TimeInterval

    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?
    /// Changed paths accumulated since the last delivery (accessed on `queue`).
    private var pendingPaths: Set<String> = []
    /// When the OLDEST still-undelivered change arrived (accessed on `queue`).
    private var firstPendingAt: Date?

    init(
        paths: [String],
        debounce: TimeInterval = 0.3,
        maxLatency: TimeInterval? = nil,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.paths = paths
        self.debounce = debounce
        // Default: a burst may delay delivery to at most 4× the debounce.
        self.maxLatency = maxLatency ?? max(debounce * 4, 1.0)
        self.onChange = onChange
        self.queue = DispatchQueue(label: "dev.hamulia.Cherminal.fswatcher", qos: .utility)
    }

    deinit { stop() }

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
                for i in 0..<numEvents {
                    let mustScan = i < cfPaths.count
                        && (eventFlags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0
                    if i < cfPaths.count {
                        // An overflowed event means "everything under this dir
                        // may have changed" — deliver the dir itself; consumers
                        // treat a non-file path as a full-rescan signal.
                        changed.append(cfPaths[i])
                        if mustScan {
                            FilesystemWatcher.logger.warning("FSEvents overflow under \(cfPaths[i], privacy: .public)")
                        }
                    }
                }
                watcher.scheduleDebouncedFire(paths: changed)
            },
            &context,
            paths as CFArray,
            UInt64(kFSEventStreamEventIdSinceNow),
            debounce,
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
        debounceItem?.cancel()
        debounceItem = nil
        pendingPaths = []
        firstPendingAt = nil
    }

    // MARK: - Debounce (trailing edge + max-latency bound)

    private func scheduleDebouncedFire(paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingPaths.formUnion(paths)
            if self.firstPendingAt == nil { self.firstPendingAt = Date() }

            // Max-latency: continuous writes re-arm a trailing debounce forever
            // (FSEvents delivers ~every `latency`, each delivery cancelling the
            // pending fire). If the oldest undelivered change has waited long
            // enough, deliver NOW instead of re-arming.
            if let first = self.firstPendingAt,
               Date().timeIntervalSince(first) >= self.maxLatency {
                self.debounceItem?.cancel()
                self.debounceItem = nil
                self.deliver()
                return
            }

            self.debounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.deliver() }
            self.debounceItem = item
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: item)
        }
    }

    /// Hand the accumulated paths to the consumer and reset. Runs on `queue`.
    private func deliver() {
        let paths = Array(pendingPaths)
        pendingPaths = []
        firstPendingAt = nil
        guard !paths.isEmpty else { return }
        onChange(paths)
    }
}
