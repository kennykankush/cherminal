import Combine
import Foundation
import GhosttyKit
import SwiftUI
import os

/// Source of truth for user-named tab bookmarks. CRUD over `SessionCache`
/// with an in-memory copy that the UI binds to.
@MainActor
final class BookmarksManager: ObservableObject {
    private static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "bookmarks")

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

    /// Persist the supplied workspace snapshot (full grids) under a user-given name.
    func create(name: String, workspaces: [PersistedWorkspace]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? defaultName() : trimmed
        let bookmark = Bookmark(name: finalName, workspaces: workspaces)
        bookmarks.insert(bookmark, at: 0)
        // Keep the in-memory order matching loadBookmarks (updated_at DESC), so
        // it can't diverge from a reload on exact-timestamp ties.
        bookmarks.sort { $0.updatedAt > $1.updatedAt }
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

    /// Open every workspace in the bookmark — full grids, through the SAME
    /// restore path session restore uses (one law): already-open conversations
    /// are skipped (a fully-open saved tab focuses instead of duplicating),
    /// agent panes resume, missing sessions fall back to shells in their room.
    /// `registry` is taken there from the coordinator; kept here for callsite
    /// stability.
    func open(
        _ bookmark: Bookmark,
        registry: ConversationRegistry,
        coordinator: TabWindowCoordinator
    ) {
        coordinator.openPersistedWorkspaces(bookmark.workspaces)
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Tabs \(formatter.string(from: .now))"
    }
}
