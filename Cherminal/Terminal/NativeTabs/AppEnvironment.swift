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
    let coordinator: TabWindowCoordinator

    private init() {
        let cache = try? SessionCache()
        let registry = ConversationRegistry(cache: cache)
        let ghostty = Ghostty.App()
        let bookmarks = BookmarksManager(cache: cache)
        self.registry = registry
        self.ghostty = ghostty
        self.bookmarks = bookmarks
        self.coordinator = TabWindowCoordinator(
            registry: registry, ghostty: ghostty, bookmarks: bookmarks)
    }
}
