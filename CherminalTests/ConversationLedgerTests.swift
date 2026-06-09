import Testing
import Foundation
@testable import Cherminal

/// The identity law — every invariant the coordinator used to re-derive ad hoc,
/// now provable: one id per open pane, unique serialization, base-over-adopted
/// preference, and the tray park/restore guards.
struct ConversationLedgerTests {

    // MARK: - Fixtures

    private func convo(_ id: String, agent: AgentKind = .claudeCode, room: String = "/Users/x/dev/room") -> Conversation {
        Conversation(id: id, agent: agent, roomPath: URL(fileURLWithPath: room),
                     sessionFile: URL(fileURLWithPath: room),
                     firstMessageAt: nil, lastActivityAt: .now, previewText: nil)
    }

    private func shellFacts(_ paneID: UUID, baseID: String, effective: Conversation? = nil) -> ConversationLedger.PaneFacts {
        let base = convo(baseID, agent: .shell)
        return .init(paneID: paneID, base: base, effective: effective ?? base)
    }

    private func agentFacts(_ paneID: UUID, id: String, agent: AgentKind = .claudeCode) -> ConversationLedger.PaneFacts {
        let c = convo(id, agent: agent)
        return .init(paneID: paneID, base: c, effective: c)
    }

    /// Deterministic shell maker for claim tests.
    private func countingShellMaker() -> ((URL) -> Conversation, () -> Int) {
        var n = 0
        let make: (URL) -> Conversation = { url in
            n += 1
            return Conversation(id: "fresh-\(n)", agent: .shell, roomPath: url,
                                sessionFile: url, firstMessageAt: nil,
                                lastActivityAt: .now, previewText: nil)
        }
        return (make, { n })
    }

    // MARK: - openPane: base beats adopted

    @Test func openPanePrefersOpenedIdentityOverAdopted() {
        let openedAs = UUID()   // pane deliberately opened as agent-1 (later in order)
        let adopted = UUID()    // shell pane that merely guessed agent-1 (earlier)
        let panes = [
            shellFacts(adopted, baseID: "shell-a", effective: convo("agent-1")),
            agentFacts(openedAs, id: "agent-1"),
        ]
        #expect(ConversationLedger.openPane(for: "agent-1", panes: panes) == openedAs)
        #expect(ConversationLedger.openPane(for: "shell-a", panes: panes) == adopted)
        #expect(ConversationLedger.openPane(for: "nope", panes: panes) == nil)
    }

    @Test func openPaneFallsBackToAdoptedWhenNoExactMatch() {
        let adopted = UUID()
        let panes = [shellFacts(adopted, baseID: "shell-a", effective: convo("agent-1"))]
        #expect(ConversationLedger.openPane(for: "agent-1", panes: panes) == adopted)
    }

    // MARK: - claimIdentities: unique serialization

    @Test func agentPanesKeepTheirIdentity() {
        let p1 = UUID(), p2 = UUID()
        let panes = [agentFacts(p1, id: "a1"), agentFacts(p2, id: "a2", agent: .codex)]
        let identity = ConversationLedger.claimIdentities(panes: panes)
        #expect(identity[p1]?.id == "a1")
        #expect(identity[p2]?.id == "a2")
    }

    @Test func duplicateAgentPaneDemotesToFreshShell() {
        let p1 = UUID(), p2 = UUID()
        let (make, count) = countingShellMaker()
        let panes = [agentFacts(p1, id: "a1"), agentFacts(p2, id: "a1")]
        let identity = ConversationLedger.claimIdentities(panes: panes, makeShell: make)
        #expect(identity[p1]?.id == "a1")
        #expect(identity[p2]?.id == "fresh-1")   // demoted, never two panes → one id
        #expect(count() == 1)
    }

    @Test func shellTakesDetectedAgentUnlessClaimed() {
        let agentPane = UUID(), shellPane = UUID()
        let panes = [
            agentFacts(agentPane, id: "a1"),
            shellFacts(shellPane, baseID: "shell-1"),
        ]
        // The shell hand-launched the SAME agent the fixed pane owns → the
        // fixed pane wins; the shell serializes as its unique base identity.
        let identity = ConversationLedger.claimIdentities(
            panes: panes, detected: [shellPane: convo("a1")])
        #expect(identity[agentPane]?.id == "a1")
        #expect(identity[shellPane]?.id == "shell-1")
    }

    @Test func shellKeepsDetectedAgentWhenUnclaimed() {
        let shellPane = UUID()
        let panes = [shellFacts(shellPane, baseID: "shell-1")]
        let identity = ConversationLedger.claimIdentities(
            panes: panes, detected: [shellPane: convo("a9", agent: .codex)])
        #expect(identity[shellPane]?.id == "a9")
        #expect(identity[shellPane]?.agent == .codex)
    }

    @Test func twoShellsAdoptingSameAgentSerializeUniquely() {
        let s1 = UUID(), s2 = UUID()
        let adopted = convo("a1")
        let panes = [
            shellFacts(s1, baseID: "shell-1", effective: adopted),
            shellFacts(s2, baseID: "shell-2", effective: adopted),
        ]
        let identity = ConversationLedger.claimIdentities(panes: panes)
        let ids = Set([identity[s1]?.id, identity[s2]?.id].compactMap { $0 })
        #expect(ids.count == 2)                       // never two panes → one id
        #expect(ids.contains("a1"))                   // first keeps the agent
        #expect(ids.contains("shell-2"))              // second falls back to base
    }

    // MARK: - dedupeForRestore

    @Test func restoreDropsDuplicatePanesAcrossWorkspaces() {
        let ws1 = PersistedWorkspace(panes: [
            persistedPane("a1"), persistedPane("s1", agent: .shell),
        ])
        let ws2 = PersistedWorkspace(panes: [
            persistedPane("a1"),   // dup of ws1's agent → dropped
            persistedPane("s2", agent: .shell),
        ])
        let out = ConversationLedger.dedupeForRestore([ws1, ws2])
        #expect(out.count == 2)   // aligned 1:1 with input
        #expect(out[0].panes.map(\.conversationID) == ["a1", "s1"])
        #expect(out[1].panes.map(\.conversationID) == ["s2"])
    }

    @Test func restoreEmptiesFullyDuplicateWorkspaceAndSkipsOpenIDs() {
        let ws1 = PersistedWorkspace(panes: [persistedPane("a1")])
        let ws2 = PersistedWorkspace(panes: [persistedPane("a1")])
        let out = ConversationLedger.dedupeForRestore([ws1, ws2], alreadyOpen: [])
        #expect(out.count == 2)
        #expect(out[0].panes.count == 1)
        #expect(out[1].panes.isEmpty)   // emptied, not dropped — caller can focus it

        // Idempotent restore: an id already open in a live pane is skipped.
        let openFiltered = ConversationLedger.dedupeForRestore([ws1], alreadyOpen: ["a1"])
        #expect(openFiltered.count == 1)
        #expect(openFiltered[0].panes.isEmpty)
    }

    // MARK: - Tray guards

    @Test func agentsAlwaysPark_shellsOnlyWithLiveMaster() {
        let agent = convo("a1")
        let shell = convo("s1", agent: .shell)
        // Agent parks regardless of master state (master check skipped).
        #expect(ConversationLedger.canPark(agent, openPanes: [], parked: [],
                                           masterAlive: { _ in false }))
        // Shell parks only when its master is actually alive.
        #expect(!ConversationLedger.canPark(shell, openPanes: [], parked: [],
                                            masterAlive: { _ in false }))
        #expect(ConversationLedger.canPark(shell, openPanes: [], parked: [],
                                           masterAlive: { _ in true }))
    }

    @Test func openOrParkedConversationNeverParksTwice() {
        let agent = convo("a1")
        // Still open in a pane (by either identity) → no park.
        let openPanes = [agentFacts(UUID(), id: "a1")]
        #expect(!ConversationLedger.canPark(agent, openPanes: openPanes, parked: [],
                                            masterAlive: { _ in true }))
        // Already parked → no second cell for one master.
        let parked = [DetachedAgent(conversation: agent)]
        #expect(!ConversationLedger.canPark(agent, openPanes: [], parked: parked,
                                            masterAlive: { _ in true }))
    }

    @Test func trayRestoreKeepsAliveUnopenedOnly() {
        let saved = [
            PersistedTab(conversationID: "alive-free", agentRaw: "claudeCode", roomPath: "/r"),
            PersistedTab(conversationID: "dead", agentRaw: "claudeCode", roomPath: "/r"),
            PersistedTab(conversationID: "alive-open", agentRaw: "codex", roomPath: "/r"),
        ]
        let open = [agentFacts(UUID(), id: "alive-open", agent: .codex)]
        let out = ConversationLedger.restorableTray(
            saved: saved, openPanes: open,
            masterAlive: { $0 != "dead" })
        #expect(out.map(\.conversationID) == ["alive-free"])
    }

    // MARK: - Sweep keep-set

    @Test func sweepKeepsSavedPanesAndTray() {
        let ws = PersistedWorkspace(panes: [persistedPane("a1")])
        let tray = [PersistedTab(conversationID: "parked-1", agentRaw: "codex", roomPath: "/r")]
        let keep = ConversationLedger.sweepKeepSet(savedWorkspaces: [ws], savedTray: tray)
        #expect(keep == Set(["a1", "parked-1"]))
    }

    // MARK: - Persisted-shape migration

    /// A legacy V2 snapshot (with layout / gridPosition / socketID / id keys)
    /// must decode into the slimmed shapes — extra keys are ignored.
    @Test func legacyWorkspaceJSONDecodesIntoSlimShape() throws {
        let legacy = """
        [{"id":"5D1B0E9B-0000-0000-0000-000000000000",
          "layout":{"rows":2,"cols":2},
          "panes":[{"id":"6F000000-0000-0000-0000-000000000000",
                    "conversationID":"a1","agentRaw":"claudeCode","roomPath":"/r",
                    "gridPosition":{"row":0,"col":1,"rowSpan":1,"colSpan":1},
                    "socketID":"a1"}]}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([PersistedWorkspace].self, from: legacy)
        #expect(decoded.count == 1)
        #expect(decoded[0].panes.map(\.conversationID) == ["a1"])
    }

    /// Old single-pane bookmark blobs ([PersistedTab]) migrate to one
    /// single-pane workspace per tab; new blobs decode directly.
    @Test func bookmarkBlobMigratesFromTabsShape() throws {
        let decoder = JSONDecoder()
        let oldBlob = """
        [{"conversationID":"a1","agentRaw":"claudeCode","roomPath":"/r"},
         {"conversationID":"s1","agentRaw":"shell","roomPath":"/r2"}]
        """.data(using: .utf8)!
        let migrated = SessionCache.decodeBookmarkWorkspaces(oldBlob, decoder: decoder)
        #expect(migrated?.count == 2)
        #expect(migrated?[0].panes.map(\.conversationID) == ["a1"])
        #expect(migrated?[1].panes.first?.agentRaw == "shell")

        let newBlob = try JSONEncoder().encode([PersistedWorkspace(panes: [persistedPane("x")])])
        let direct = SessionCache.decodeBookmarkWorkspaces(newBlob, decoder: decoder)
        #expect(direct?.first?.panes.map(\.conversationID) == ["x"])
    }

    // MARK: - Helpers

    private func persistedPane(_ id: String, agent: AgentKind = .claudeCode) -> PersistedPane {
        PersistedPane(conversationID: id, agentRaw: agent.rawValue,
                      roomPath: "/Users/x/dev/room", role: nil)
    }
}
