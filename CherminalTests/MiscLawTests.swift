import Testing
import Foundation
@testable import Cherminal

/// The grid geometry law: layout derives from pane COUNT (this is why
/// geometry isn't persisted — count + order reproduces it exactly).
struct GridLayoutTests {

    @Test func fitPicksNearSquareLayouts() {
        #expect(GridLayout.fit(1) == GridLayout(rows: 1, cols: 1))
        #expect(GridLayout.fit(2) == GridLayout(rows: 1, cols: 2))
        #expect(GridLayout.fit(3) == GridLayout(rows: 2, cols: 2))
        #expect(GridLayout.fit(4) == GridLayout(rows: 2, cols: 2))
        #expect(GridLayout.fit(5) == GridLayout(rows: 2, cols: 3))
        #expect(GridLayout.fit(9) == GridLayout(rows: 3, cols: 3))
        #expect(GridLayout.fit(10) == GridLayout(rows: 3, cols: 4))
        #expect(GridLayout.fit(16) == GridLayout(rows: 4, cols: 4))
        // Degenerate input clamps to a sane single cell.
        #expect(GridLayout.fit(0) == GridLayout(rows: 1, cols: 1))
        // Every count fits within its layout's capacity.
        for n in 1...16 { #expect(GridLayout.fit(n).capacity >= n) }
    }

    @Test func positionFollowsReadingOrder() {
        let layout = GridLayout(rows: 2, cols: 3)
        #expect(layout.position(for: 0) == GridPosition(row: 0, col: 0))
        #expect(layout.position(for: 2) == GridPosition(row: 0, col: 2))
        #expect(layout.position(for: 3) == GridPosition(row: 1, col: 0))
        #expect(layout.position(for: 5) == GridPosition(row: 1, col: 2))
    }
}

/// git status --porcelain parsing — the helpers were split out as testable
/// but never tested.
struct GitStatusParseTests {

    @Test func changedPathHandlesRenamesAndPlainEntries() {
        #expect(GitStatusReader.changedPath(from: " M Sources/App.swift") == "Sources/App.swift")
        #expect(GitStatusReader.changedPath(from: "?? new file.txt") == "new file.txt")
        #expect(GitStatusReader.changedPath(from: "R  old.txt -> new.txt") == "new.txt")
    }

    @Test func aheadBehindNumbersParse() {
        let info = "main...origin/main [ahead 2, behind 7]"
        #expect(GitStatusReader.number(after: "ahead ", in: info) == 2)
        #expect(GitStatusReader.number(after: "behind ", in: info) == 7)
        #expect(GitStatusReader.number(after: "ahead ", in: "main...origin/main") == nil)
    }

    @Test func shortstatParsesInsertionsAndDeletions() {
        #expect(GitStatusReader.parseShortstat(" 3 files changed, 120 insertions(+), 45 deletions(-)") == (120, 45))
        #expect(GitStatusReader.parseShortstat(" 1 file changed, 9 insertions(+)") == (9, 0))
        #expect(GitStatusReader.parseShortstat("") == (0, 0))
    }
}

/// Burst detection — distinctive CLI phrasings only, so a chat that merely
/// DISCUSSES usage limits can't flag the account.
struct BurstDetectorTests {

    @Test func codexBannerTrips() {
        let banner = "You've hit your usage limit. Visit platform/usage to purchase more credits."
        #expect(BurstDetector.isBursting(agent: .codex, visibleText: banner))
        #expect(BurstDetector.isBursting(agent: .codex, visibleText: "HIT YOUR USAGE LIMIT now"))
    }

    /// Claude's banners, verified against the installed binary's composer
    /// (`You've hit your ${label}…` + the "— check plan" status variant).
    @Test func claudeBannerFamilyTrips() {
        #expect(BurstDetector.isBursting(agent: .claudeCode,
            visibleText: "You've hit your weekly limit · resets 3am"))
        #expect(BurstDetector.isBursting(agent: .claudeCode,
            visibleText: "You've hit your session limit"))
        #expect(BurstDetector.isBursting(agent: .claudeCode,
            visibleText: "You\u{2019}ve hit your Opus limit"))   // curly apostrophe
        #expect(BurstDetector.isBursting(agent: .claudeCode,
            visibleText: "status: usage limit reached — check plan"))
    }

    @Test func claudeApproachingWarningAndDiscussionDoNotTrip() {
        // The APPROACHING warning is not a burst.
        #expect(!BurstDetector.isBursting(agent: .claudeCode,
            visibleText: "You're close to your usage limit"))
        // Transient rate limiting is not a burst.
        #expect(!BurstDetector.isBursting(agent: .claudeCode,
            visibleText: "rate limited — wait and retry"))
        // Talking ABOUT limits isn't a burst.
        #expect(!BurstDetector.isBursting(agent: .claudeCode,
            visibleText: "let's discuss the usage limit semantics"))
    }

    @Test func discussionAndOtherAgentsDoNotTrip() {
        // Talking ABOUT limits isn't a burst.
        #expect(!BurstDetector.isBursting(agent: .codex, visibleText: "let's discuss usage limits in the API"))
        #expect(!BurstDetector.isBursting(agent: .shell, visibleText: "hit your usage limit"))
    }
}

/// Resume-command construction — the exact line spawned into a pane.
struct TerminalCommandTests {

    private func convo(_ id: String, agent: AgentKind) -> Conversation {
        Conversation(id: id, agent: agent,
                     roomPath: URL(fileURLWithPath: "/Users/x/dev/room"),
                     sessionFile: URL(fileURLWithPath: "/Users/x/dev/room"),
                     firstMessageAt: nil, lastActivityAt: .now, previewText: nil)
    }

    @Test func claudeResumeIsDtachWrappedWithBypassFlags() throws {
        let id = "12345678-aaaa-bbbb-cccc-1234567890ab"
        let cmd = try #require(TerminalCommand.resume(for: convo(id, agent: .claudeCode)))
        #expect(cmd.contains(" -A "))                          // reattach-or-create
        #expect(cmd.contains("\(id).sock"))                    // socket keyed on the session id
        #expect(cmd.contains("--dangerously-skip-permissions --resume \(id)"))
        #expect(cmd.contains("/bin/sh -c"))                    // inner line runs in-master
    }

    @Test func codexResumeUsesItsOwnBypassFlag() throws {
        let id = "87654321-dddd-eeee-ffff-0987654321ba"
        let cmd = try #require(TerminalCommand.resume(for: convo(id, agent: .codex)))
        #expect(cmd.contains("--dangerously-bypass-approvals-and-sandbox resume \(id)"))
        #expect(cmd.contains("\(id).sock"))
    }

    @Test func unsafeSessionIDsAndUnknownAgentsRefuseToBuild() {
        // A malformed id must never reach a shell line (injection guard).
        #expect(TerminalCommand.resume(for: convo("abc; rm -rf /", agent: .claudeCode)) == nil)
        #expect(TerminalCommand.resume(for: convo("$(boom)", agent: .codex)) == nil)
        // Unknown agents spawn a plain shell (no command override).
        #expect(TerminalCommand.resume(for: convo("12345678-aaaa-bbbb-cccc-1234567890ab", agent: .unknown)) == nil)
    }
}

/// Pins + bookmarks round-trips through the SQLite cache (the conversations
/// table had tests; the user-data tables didn't).
struct CacheUserDataTests {

    private func tempCache() throws -> SessionCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SessionCache(url: dir.appendingPathComponent("registry.sqlite"))
    }

    @Test func pinsRoundTripAndUnpin() throws {
        let cache = try tempCache()
        cache.setPinned("a", pinned: true)
        cache.setPinned("b", pinned: true)
        #expect(cache.pinnedSessionIDs() == ["a", "b"])
        cache.setPinned("a", pinned: false)
        #expect(cache.pinnedSessionIDs() == ["b"])
        cache.setPinned("b", pinned: true)   // idempotent re-pin
        #expect(cache.pinnedSessionIDs() == ["b"])
    }

    @Test func bookmarksRoundTripWithFullGridsAndTabNames() throws {
        let cache = try tempCache()
        let ws = PersistedWorkspace(name: "fleet", panes: [
            PersistedPane(conversationID: "a1", agentRaw: "claudeCode", roomPath: "/r", role: nil),
            PersistedPane(conversationID: "s1", agentRaw: "shell", roomPath: "/r", role: nil),
        ])
        let bookmark = Bookmark(name: "My group", workspaces: [ws])
        cache.saveBookmark(bookmark)

        let loaded = cache.loadBookmarks()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "My group")
        #expect(loaded.first?.workspaces.first?.name == "fleet")
        #expect(loaded.first?.workspaces.first?.panes.map(\.conversationID) == ["a1", "s1"])

        cache.deleteBookmark(id: bookmark.id)
        #expect(cache.loadBookmarks().isEmpty)
    }
}
