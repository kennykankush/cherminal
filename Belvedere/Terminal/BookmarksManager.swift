import Combine
import Foundation
import GhosttyKit
import SwiftUI
import os

/// Source of truth for user-named tab bookmarks. CRUD over `SessionCache`
/// with an in-memory copy that the UI binds to.
@MainActor
final class BookmarksManager: ObservableObject {
    private static let logger = Logger(subsystem: "dev.hamulia.Belvedere", category: "bookmarks")

    @Published private(set) var bookmarks: [Bookmark] = []

    private let cache: SessionCache?

    init(cache: SessionCache? = nil) {
        self.cache = cache
        reload()
    }

    /// Pull the current bookmark set from disk. Called on launch and after
    /// any external mutation (none today, but kept for future external
    /// editors / sync).
    func reload() {
        guard let cache else { return }
        bookmarks = cache.loadBookmarks()
    }

    /// Persist the supplied tab snapshot under a user-given name.
    func create(name: String, tabs: [PersistedTab]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? defaultName() : trimmed
        let bookmark = Bookmark(name: finalName, tabs: tabs)
        bookmarks.insert(bookmark, at: 0)
        cache?.saveBookmark(bookmark)
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        var updated = bookmarks[index]
        updated.name = trimmed
        updated.updatedAt = .now
        bookmarks[index] = updated
        // Re-sort so most-recently-edited bubbles up — matches Chrome.
        bookmarks.sort { $0.updatedAt > $1.updatedAt }
        cache?.saveBookmark(updated)
    }

    func delete(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        cache?.deleteBookmark(id: id)
    }

    /// Open every tab in the bookmark, reusing TabsManager's openOrFocus so
    /// duplicates collapse and existing tabs just get focused. Shell entries
    /// synthesize a shell Conversation at the persisted cwd.
    func open(
        _ bookmark: Bookmark,
        tabs tabsManager: TabsManager,
        registry: ConversationRegistry,
        ghosttyApp: ghostty_app_t,
        configBuilder: (Conversation) -> Ghostty.SurfaceConfiguration
    ) {
        for persisted in bookmark.tabs {
            let convo: Conversation
            if persisted.agentRaw == AgentKind.shell.rawValue {
                convo = Conversation.shellConversation(cwd: URL(fileURLWithPath: persisted.roomPath))
            } else if let real = registry.conversation(id: persisted.conversationID) {
                convo = real
            } else {
                continue
            }
            tabsManager.openOrFocus(convo, in: ghosttyApp, configBuilder: configBuilder)
        }
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Tabs \(formatter.string(from: .now))"
    }
}
