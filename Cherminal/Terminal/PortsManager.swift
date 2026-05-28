import Combine
import Foundation

/// Watches local dev-server ports (the "Port" tab). Polls `PortScanner` on a
/// timer off the main thread, attributing each port to a room/conversation.
/// Pure external observation — lsof/ps only, no injection.
@MainActor
final class PortsManager: ObservableObject {
    @Published private(set) var ports: [DevPort] = []

    private weak var registry: ConversationRegistry?
    private weak var coordinator: TabWindowCoordinator?
    private var timer: Timer?
    private var scanning = false

    /// Dev roots a server's cwd must fall under to count as "ours".
    private let devRoots: [String] = {
        let home = NSHomeDirectory()
        return [home + "/dev"]
    }()

    init(registry: ConversationRegistry, coordinator: TabWindowCoordinator) {
        self.registry = registry
        self.coordinator = coordinator
    }

    /// Begin polling. Idempotent; safe to call when the Port tab appears.
    func start(interval: TimeInterval = 4) {
        guard timer == nil else { return }
        Task { await self.scan() }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func scanNow() {
        Task { await scan() }
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let roomPaths = registry?.rooms.map { $0.path.path } ?? []
        let tabPIDs = coordinator?.tabForegroundPIDs() ?? [:]
        let context = PortScanner.Context(roomPaths: roomPaths, tabPIDs: tabPIDs, devRoots: devRoots)

        let scanned = await Task.detached(priority: .utility) {
            PortScanner.scan(context)
        }.value

        if scanned != ports { ports = scanned }
    }
}
