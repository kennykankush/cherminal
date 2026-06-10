import Foundation

/// The app's shared services, owned outside any SwiftUI scene so every native
/// tab window can read one source of truth. Built lazily on first access —
/// `ghostty_init` must have already run (see CherminalAppDelegate).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let registry: ConversationRegistry
    let ghostty: Ghostty.App
    let bookmarks: BookmarksManager
    let pins: PinsManager
    let labels = ConversationLabelsManager()   // user-set name + note per conversation
    let coordinator: TabWindowCoordinator
    let ports: PortsManager
    let caffeine = CaffeineManager()
    /// Supervisor-registered claude sessions (background + other-terminal).
    let backgroundAgents = BackgroundAgentsMonitor()
    let metrics: MetricsRecorder

    private init() {
        let cache = try? SessionCache()
        // ONE kernel FSEventStream over the agent session roots, fanned out to
        // every consumer at its own cadence (registry 2.5s, coordinator 0.3s).
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let sessionEvents = FilesystemWatcher(paths: [
            home.appendingPathComponent(".claude/projects", isDirectory: true).path,
            home.appendingPathComponent(".codex/sessions", isDirectory: true).path,
        ].filter { FileManager.default.fileExists(atPath: $0) })
        let registry = ConversationRegistry(cache: cache, sessionEvents: sessionEvents)
        let ghostty = Ghostty.App()
        let bookmarks = BookmarksManager(cache: cache)
        let pins = PinsManager(cache: cache)
        let coordinator = TabWindowCoordinator(
            registry: registry, ghostty: ghostty, bookmarks: bookmarks,
            sessionEvents: sessionEvents)
        self.registry = registry
        self.ghostty = ghostty
        self.bookmarks = bookmarks
        self.pins = pins
        self.coordinator = coordinator
        self.ports = PortsManager(registry: registry, coordinator: coordinator)
        self.metrics = MetricsRecorder(coordinator: coordinator)
    }
}
