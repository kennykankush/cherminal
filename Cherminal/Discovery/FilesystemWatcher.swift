import CoreServices
import Foundation
import os

/// Watches one or more directory trees and fires a callback whenever a file
/// underneath changes. Backed by FSEvents so it catches line-by-line writes
/// into nested session files (DispatchSource on a directory FD would only
/// fire for the directory itself, not its descendants).
///
/// Events are coalesced inside FSEvents using `latency` and we apply our own
/// Swift-side debounce on top, so a burst of writes during a single Claude
/// Code turn results in exactly one callback to the registry.
final class FilesystemWatcher {
    private static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "watcher")

    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private let debounce: TimeInterval

    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?

    init(
        paths: [String],
        debounce: TimeInterval = 0.3,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.paths = paths
        self.debounce = debounce
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
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FilesystemWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleDebouncedFire()
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
    }

    // MARK: - Debounce

    private func scheduleDebouncedFire() {
        // FSEvents already coalesces by `latency`, but a long Claude Code turn
        // emits many distinct events. A second debounce here ensures the
        // registry never runs more than one rescan per logical change.
        queue.async { [weak self] in
            guard let self else { return }
            self.debounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.onChange() }
            self.debounceItem = item
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: item)
        }
    }
}
