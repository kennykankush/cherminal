import Foundation

/// THE merge laws for the conversation registry — how parsed results fold into
/// the published list. Pure, so the rules are testable; the registry delegates.
///
/// The load-bearing rule: two session FILES can legitimately share one
/// conversation ID (codex forks a new rollout file on resume; a session
/// bridged across runtimes) — the most recently ACTIVE file owns the id.
/// This is what makes fork-tracking converge, and why `uniqueKeysWithValues`
/// (which traps on duplicates) must never be used on agent-derived ids.
enum RegistryMerge {

    /// Collapse conversations to one per id, most-recently-active wins.
    static func newestByID(_ conversations: [Conversation]) -> [String: Conversation] {
        Dictionary(conversations.map { ($0.id, $0) },
                   uniquingKeysWith: { $0.lastActivityAt >= $1.lastActivityAt ? $0 : $1 })
    }

    /// Fold an incremental batch (the watcher's changed files) into the
    /// existing list:
    ///   • removed paths drop the conversation that file backed
    ///   • a parsed file claims its id UNLESS a different, more recently
    ///     active file already owns it (the fork rule — an old rollout's
    ///     re-parse must not steal the id back from the live fork)
    /// Returns the merged list sorted most-recent-first (publish order).
    static func applyingIncremental(
        existing: [Conversation],
        parsed: [Conversation],
        removedPaths: Set<String>
    ) -> [Conversation] {
        var byID = newestByID(existing)
        if !removedPaths.isEmpty {
            byID = byID.filter { !removedPaths.contains($0.value.sessionFile.path) }
        }
        for convo in parsed {
            if let current = byID[convo.id],
               current.sessionFile.path != convo.sessionFile.path,
               current.lastActivityAt > convo.lastActivityAt {
                continue   // a newer file already owns this id (fork rule)
            }
            byID[convo.id] = convo
        }
        return byID.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
