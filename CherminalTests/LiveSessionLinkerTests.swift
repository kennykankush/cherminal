import Testing
import Foundation
@testable import Cherminal

struct LiveSessionLinkerTests {
    private let roots = ["/Users/me/.claude/projects/", "/Users/me/.codex/sessions/"]

    @Test func parsesCodexOpenFileAndClaudeCwdOnly() {
        // Two processes: Codex holds its rollout open; Claude shows only a cwd
        // (it doesn't keep the session file open).
        let raw = """
        p29999
        ccodex
        fcwd
        n/Users/me/dev/foo
        f34
        n/Users/me/.codex/sessions/2026/05/28/rollout-2026-05-28-abc.jsonl
        p35074
        cclaude
        fcwd
        n/Users/me/dev/constant
        ftxt
        n/opt/homebrew/bin/node
        """

        let info = LiveSessionLinker.parse(raw, roots: roots)

        #expect(info[29999]?.command == "codex")
        #expect(info[29999]?.cwd == "/Users/me/dev/foo")
        #expect(info[29999]?.openSessionFile == "/Users/me/.codex/sessions/2026/05/28/rollout-2026-05-28-abc.jsonl")

        #expect(info[35074]?.command == "claude")
        #expect(info[35074]?.cwd == "/Users/me/dev/constant")
        #expect(info[35074]?.openSessionFile == nil)   // Claude doesn't hold it open
    }

    @Test func ignoresNonSessionOpenFiles() {
        // A .jsonl outside the session roots must not be mistaken for a session.
        let raw = """
        p1
        cnode
        f3
        n/Users/me/dev/foo/package-lock.jsonl
        """
        let info = LiveSessionLinker.parse(raw, roots: roots)
        #expect(info[1]?.openSessionFile == nil)
    }
}
