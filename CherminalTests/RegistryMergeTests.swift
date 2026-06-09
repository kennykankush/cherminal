import Testing
import Foundation
@testable import Cherminal

/// The registry's merge laws — the codex fork rule (two files, one id, newest
/// file owns it) and incremental fold-in, previously inline and untested.
struct RegistryMergeTests {

    private func convo(_ id: String, file: String, at: TimeInterval,
                       agent: AgentKind = .codex) -> Conversation {
        Conversation(id: id, agent: agent,
                     roomPath: URL(fileURLWithPath: "/Users/x/dev/room"),
                     sessionFile: URL(fileURLWithPath: file),
                     firstMessageAt: nil,
                     lastActivityAt: Date(timeIntervalSince1970: at),
                     previewText: nil)
    }

    @Test func duplicateIDKeepsMostRecentlyActive() {
        // Codex fork: old rollout + the live fork share one session id.
        let old = convo("s1", file: "/rollout-old.jsonl", at: 100)
        let fork = convo("s1", file: "/rollout-fork.jsonl", at: 200)
        let byID = RegistryMerge.newestByID([old, fork])
        #expect(byID.count == 1)
        #expect(byID["s1"]?.sessionFile.path == "/rollout-fork.jsonl")
        // Order-independent.
        #expect(RegistryMerge.newestByID([fork, old])["s1"]?.sessionFile.path == "/rollout-fork.jsonl")
    }

    @Test func incrementalRemovalDropsTheBackingFile() {
        let a = convo("a", file: "/a.jsonl", at: 100)
        let b = convo("b", file: "/b.jsonl", at: 200)
        let out = RegistryMerge.applyingIncremental(
            existing: [a, b], parsed: [], removedPaths: ["/a.jsonl"])
        #expect(out.map(\.id) == ["b"])
    }

    @Test func staleForkReparseCannotStealTheID() {
        // The live fork owns s1; a watcher event re-parses the OLD rollout.
        let fork = convo("s1", file: "/fork.jsonl", at: 200)
        let oldReparse = convo("s1", file: "/old.jsonl", at: 100)
        let out = RegistryMerge.applyingIncremental(
            existing: [fork], parsed: [oldReparse], removedPaths: [])
        #expect(out.first?.sessionFile.path == "/fork.jsonl")
    }

    @Test func newerParseReplacesAndSortsMostRecentFirst() {
        let a = convo("a", file: "/a.jsonl", at: 100)
        let aGrown = convo("a", file: "/a.jsonl", at: 300)   // same file, new activity
        let b = convo("b", file: "/b.jsonl", at: 200)
        let out = RegistryMerge.applyingIncremental(
            existing: [a, b], parsed: [aGrown], removedPaths: [])
        #expect(out.map(\.id) == ["a", "b"])                 // most-recent-first
        #expect(out.first?.lastActivityAt == Date(timeIntervalSince1970: 300))
    }
}
