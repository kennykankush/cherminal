import Combine
import Foundation

/// Tracks which single conversations the user has pinned (the "Pin" tab in
/// the context pane). Backed by the cache's `pin_state` table. Distinct from
/// bookmarks, which are multi-tab groups (the "Group" tab).
@MainActor
final class PinsManager: ObservableObject {
    @Published private(set) var pinnedIDs: Set<String> = []

    private let cache: SessionCache?

    init(cache: SessionCache? = nil) {
        self.cache = cache
        reload()
    }

    func reload() {
        pinnedIDs = cache?.pinnedSessionIDs() ?? []
    }

    func isPinned(_ conversationID: String) -> Bool {
        pinnedIDs.contains(conversationID)
    }

    func toggle(_ conversationID: String) {
        let nowPinned = !pinnedIDs.contains(conversationID)
        cache?.setPinned(conversationID, pinned: nowPinned)
        if nowPinned { pinnedIDs.insert(conversationID) }
        else { pinnedIDs.remove(conversationID) }
    }
}
