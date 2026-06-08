import AppKit
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

    private var cancellables = Set<AnyCancellable>()
    // The scan spawns 3 subprocesses (lsof, lsof, ps -axo) each fire, so this is
    // the heaviest standing poll. 12s (was 4s) is plenty for an ambient footer,
    // and it's paused entirely while the app is backgrounded (see shouldPoll).
    private let interval: TimeInterval = 12

    init(registry: ConversationRegistry, coordinator: TabWindowCoordinator) {
        self.registry = registry
        self.coordinator = coordinator

        // Poll while the inspector (which hosts the ports footer) is shown and
        // at least one tab exists. Driven off coordinator.tabCount + the app-wide
        // inspector flag — NOT a SwiftUI view's onAppear/onDisappear, which an
        // AppKit window close can skip, leaking the poll forever.
        coordinator.$tabCount
            .sink { [weak self] _ in self?.refreshPolling() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.refreshPolling() }
            .store(in: &cancellables)
        // Pause/resume the lsof+ps scan as the app loses/gains focus (energy).
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.refreshPolling() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPolling() }
            .store(in: &cancellables)
        refreshPolling()
    }

    private func shouldPoll() -> Bool {
        let hasTabs = (coordinator?.tabCount ?? 0) > 0
        // Mirrors @AppStorage("cherminal.showContext"), default true.
        let inspectorShown = UserDefaults.standard.object(forKey: "cherminal.showContext") as? Bool ?? true
        // Don't fire the lsof+ps scan while the app is in the background — the
        // ports footer isn't on screen, so it's pure battery drain. Resumes on
        // reactivation (we re-evaluate on the active/resign notifications above).
        return hasTabs && inspectorShown && NSApp.isActive
    }

    private func refreshPolling() {
        shouldPoll() ? startPolling() : stopPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        Task { await self.scan() }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        timer = t
    }

    private func stopPolling() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        // Don't let an in-flight scan straddling stop→start block the next
        // session's first scan (it would no-op on the `scanning` guard).
        scanning = false
        if !ports.isEmpty { ports = [] }
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
