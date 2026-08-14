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

    // MARK: - Wrapper (shim) folding

    /// The npm `codex` is a node shim that re-execs the real binary as a child,
    /// so the tab's foreground process is `node` holding nothing open while the
    /// child holds the rollout. The child's identity must fold onto the pid the
    /// caller asked about, or the tab stays a bare shell forever.
    @Test func foldsAgentChildOntoNodeShim() {
        let probed: [Int32: LiveSessionLinker.ProcessInfo] = [
            10953: .init(command: "node", cwd: "/Users/me/dev/rifter",
                         openSessionFile: nil, resumeID: nil),
            10954: .init(command: "codex", cwd: "/Users/me/dev/rifter",
                         openSessionFile: "/Users/me/.codex/sessions/2026/08/13/rollout-abc.jsonl",
                         resumeID: nil),
        ]
        let resolved = LiveSessionLinker.resolve(root: 10953, descendants: [10954],
                                                 probed: probed, resumed: [:])
        #expect(resolved?.command == "codex")
        #expect(resolved?.openSessionFile == "/Users/me/.codex/sessions/2026/08/13/rollout-abc.jsonl")
        #expect(resolved?.cwd == "/Users/me/dev/rifter")
    }

    /// A foreground process that already identifies itself keeps its own
    /// identity — children never override a real agent.
    @Test func agentForegroundIgnoresChildren() {
        let probed: [Int32: LiveSessionLinker.ProcessInfo] = [
            1: .init(command: "claude", cwd: "/Users/me/dev/foo", openSessionFile: nil, resumeID: nil),
            2: .init(command: "codex", cwd: "/tmp",
                     openSessionFile: "/Users/me/.codex/sessions/x.jsonl", resumeID: nil),
        ]
        let resolved = LiveSessionLinker.resolve(root: 1, descendants: [2], probed: probed, resumed: [:])
        #expect(resolved?.command == "claude")
        #expect(resolved?.openSessionFile == nil)
    }

    /// A shell with no agent anywhere under it stays a shell.
    @Test func plainShellIsNotFolded() {
        let probed: [Int32: LiveSessionLinker.ProcessInfo] = [
            1: .init(command: "zsh", cwd: "/Users/me", openSessionFile: nil, resumeID: nil),
            2: .init(command: "rg", cwd: "/Users/me", openSessionFile: nil, resumeID: nil),
        ]
        let resolved = LiveSessionLinker.resolve(root: 1, descendants: [2], probed: probed, resumed: [:])
        #expect(resolved?.command == "zsh")
        #expect(resolved?.openSessionFile == nil)
    }

    /// `codex resume <id>` reaches the shim's argv or the child's — either is
    /// the exact link, so the whole chain is searched.
    @Test func resumeIDFoundOnChildOfShim() {
        let probed: [Int32: LiveSessionLinker.ProcessInfo] = [
            10: .init(command: "node", cwd: "/Users/me", openSessionFile: nil, resumeID: nil),
            11: .init(command: "codex", cwd: "/Users/me", openSessionFile: nil, resumeID: nil),
        ]
        let resolved = LiveSessionLinker.resolve(root: 10, descendants: [11],
                                                 probed: probed, resumed: [11: "019ffa5d-508a"])
        #expect(resolved?.resumeID == "019ffa5d-508a")
    }

    // MARK: - Descendant walk

    @Test func descendantsAreBoundedAndSkipOtherRoots() {
        // 1 → 2 → 3 → 4 (depth 3: 4 is out of reach); 2 is also another pane's
        // foreground pid, so the walk must not descend through it.
        let tree: [Int32: [Int32]] = [1: [2, 5], 2: [3], 3: [4], 5: [6]]
        let bounded = LiveSessionLinker.descendantsByRoot(pids: [1], childrenByParent: tree)
        #expect(bounded[1] == [2, 5, 3, 6])   // breadth-first, depth 2

        let shared = LiveSessionLinker.descendantsByRoot(pids: [1, 2], childrenByParent: tree)
        #expect(shared[1]?.contains(2) == false)
        #expect(shared[1]?.contains(3) == false)   // reachable only through root 2
        #expect(shared[2] == [3, 4])               // root 2 gets its own full walk
    }

    @Test func descendantWalkCapsPerRoot() {
        let tree: [Int32: [Int32]] = [1: Array(2...50)]
        let found = LiveSessionLinker.descendantsByRoot(pids: [1], childrenByParent: tree)
        #expect(found[1]?.count == 8)
    }

    @Test func noProcessTableMeansForegroundOnly() {
        #expect(LiveSessionLinker.descendantsByRoot(pids: [1], childrenByParent: nil).isEmpty)
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
