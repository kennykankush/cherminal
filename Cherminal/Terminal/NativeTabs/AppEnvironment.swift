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
    let coordinator: TabWindowCoordinator
    let ports: PortsManager
    let caffeine = CaffeineManager()
    let metrics: MetricsRecorder
    let kanban: KanbanManager
    let swarms: SwarmManager

    private init() {
        let cache = try? SessionCache()
        let registry = ConversationRegistry(cache: cache)
        let ghostty = Ghostty.App()
        let bookmarks = BookmarksManager(cache: cache)
        let pins = PinsManager(cache: cache)
        let coordinator = TabWindowCoordinator(
            registry: registry, ghostty: ghostty, bookmarks: bookmarks)
        self.registry = registry
        self.ghostty = ghostty
        self.bookmarks = bookmarks
        self.pins = pins
        self.coordinator = coordinator
        self.ports = PortsManager(registry: registry, coordinator: coordinator)
        self.metrics = MetricsRecorder(coordinator: coordinator)
        self.kanban = KanbanManager(cache: cache)
        self.swarms = SwarmManager(cache: cache)
    }
}
