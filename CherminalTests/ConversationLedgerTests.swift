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

    // MARK: - Socket identity (persist + restore plan)

    /// Only an ADOPTED shell (hand-launched agent) persists its foreign socket.
    /// Agent panes and plain shells persist nil; a demoted duplicate (agent
    /// base, fresh-shell claim) must NEVER leak its base socket — that socket
    /// belongs to the other pane's claim.
    @Test func socketPersistsOnlyForAdoptedShells() {
        let shellBase = convo("shell-1", agent: .shell)
        let agent = convo("a1")
        #expect(ConversationLedger.socketToPersist(base: shellBase, claimed: agent) == "shell-1")
        #expect(ConversationLedger.socketToPersist(base: shellBase, claimed: shellBase) == nil)
        #expect(ConversationLedger.socketToPersist(base: agent, claimed: agent) == nil)
        // Demoted duplicate: agent base, fresh-shell claim → nil.
        #expect(ConversationLedger.socketToPersist(base: agent, claimed: convo("fresh-9", agent: .shell)) == nil)
    }

    @Test func restorePlanReattachesLiveForeignSocketElseColdResumes() {
        let handLaunched = PersistedPane(conversationID: "a1", agentRaw: "claudeCode",
                                         roomPath: "/r", role: nil, socketID: "shell-1")
        // Master alive → reattach the wrapped shell (the agent is inside it).
        #expect(ConversationLedger.restorePlan(for: handLaunched, masterAlive: { $0 == "shell-1" })
                == .attachLiveShell(socketID: "shell-1"))
        // Master dead (Mac restart) → cold resume by conversation id.
        #expect(ConversationLedger.restorePlan(for: handLaunched, masterAlive: { _ in false })
                == .resumeAgent)
        // Sidebar-opened agent (no foreign socket) → resume; liveness is never
        // even consulted (dtach -A reattaches its own socket anyway).
        #expect(ConversationLedger.restorePlan(for: persistedPane("a2"), masterAlive: { _ in true })
                == .resumeAgent)
        // Shell pane → shell, reusing its id/socket.
        #expect(ConversationLedger.restorePlan(for: persistedPane("s1", agent: .shell),
                                               masterAlive: { _ in false })
                == .shell(id: "s1"))
    }

    // MARK: - Sweep keep-set

    @Test func sweepKeepsSavedPanesForeignSocketsAndTray() {
        let ws = PersistedWorkspace(panes: [
            persistedPane("a1"),
            PersistedPane(conversationID: "a2", agentRaw: "claudeCode", roomPath: "/r",
                          role: nil, socketID: "shell-7"),   // hand-launch's live master
        ])
        let tray = [PersistedTab(conversationID: "parked-1", agentRaw: "codex", roomPath: "/r")]
        let keep = ConversationLedger.sweepKeepSet(savedWorkspaces: [ws], savedTray: tray)
        #expect(keep == Set(["a1", "a2", "shell-7", "parked-1"]))
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

    /// A user's tab rename rides the workspace snapshot: round-trips through
    /// JSON, decodes nil from pre-feature snapshots, and survives the restore
    /// dedup untouched (dedupe filters panes, never the name).
    @Test func tabNameRoundTripsAndSurvivesDedupe() throws {
        let ws = PersistedWorkspace(name: "review fleet", panes: [persistedPane("a1")])
        let decoded = try JSONDecoder().decode(
            [PersistedWorkspace].self, from: JSONEncoder().encode([ws]))
        #expect(decoded.first?.name == "review fleet")

        let legacy = try JSONDecoder().decode([PersistedWorkspace].self, from: """
        [{"panes":[{"conversationID":"x","agentRaw":"shell","roomPath":"/r"}]}]
        """.data(using: .utf8)!)
        #expect(legacy.first?.name == nil)

        let deduped = ConversationLedger.dedupeForRestore([ws], alreadyOpen: ["a1"])
        #expect(deduped.first?.name == "review fleet")
        #expect(deduped.first?.panes.isEmpty == true)
    }

    // MARK: - Hand-launch detection order (Fix A's law)

    @Test func detectionPrefersArgvThenOpenFileThenRecency() {
        let room = "/Users/x/dev/room"
        let older = timed("c-old", room: room, at: 100)
        let newer = timed("c-new", room: room, at: 200)
        let codexConvo = timed("x-1", room: room, at: 50, agent: .codex,
                               file: "/Users/x/.codex/sessions/r.jsonl")
        let candidates = [older, newer, codexConvo]

        // 1. argv resume id — exact, beats everything.
        let argv = LiveSessionLinker.ProcessInfo(
            command: "claude", cwd: room, openSessionFile: nil, resumeID: "c-old")
        #expect(ConversationLedger.detectConversation(info: argv, candidates: candidates)?.id == "c-old")

        // 2. codex's open rollout file — exact.
        let openFile = LiveSessionLinker.ProcessInfo(
            command: "codex", cwd: room,
            openSessionFile: "/Users/x/.codex/sessions/r.jsonl", resumeID: nil)
        #expect(ConversationLedger.detectConversation(info: openFile, candidates: candidates)?.id == "x-1")

        // 3. claude with no exact signal → most-recently-active in the room.
        let bare = LiveSessionLinker.ProcessInfo(
            command: "claude", cwd: room, openSessionFile: nil, resumeID: nil)
        #expect(ConversationLedger.detectConversation(info: bare, candidates: candidates)?.id == "c-new")

        // Not an agent / no cwd / no info → nothing.
        let shell = LiveSessionLinker.ProcessInfo(
            command: "zsh", cwd: room, openSessionFile: nil, resumeID: nil)
        #expect(ConversationLedger.detectConversation(info: shell, candidates: candidates) == nil)
        #expect(ConversationLedger.detectConversation(info: nil, candidates: candidates) == nil)
    }

    // MARK: - Tray anti-leak (parked shells)

    @Test func trayReapsAgedAndOverCapShellsKeepingNewest() {
        let now = Date(timeIntervalSince1970: 100_000)
        let day: TimeInterval = 86_400
        var shells: [(id: String, detachedAt: Date)] = [
            (id: "ancient", detachedAt: now.addingTimeInterval(-2 * day)),   // over maxAge
        ]
        // 5 fresh shells, newest last.
        for i in 0..<5 {
            shells.append((id: "s\(i)", detachedAt: now.addingTimeInterval(Double(i) * 60 - 3600)))
        }
        // Cap 3: the ancient one reaps by age; of the 5 fresh, the 2 OLDEST reap.
        let reap = ConversationLedger.shellTrayReaps(
            parkedShells: shells, now: now, cap: 3, maxAge: day)
        #expect(reap == Set(["ancient", "s0", "s1"]))

        // Under cap, nothing fresh reaps.
        #expect(ConversationLedger.shellTrayReaps(
            parkedShells: Array(shells.dropFirst()), now: now, cap: 16, maxAge: day).isEmpty)
        #expect(ConversationLedger.shellTrayReaps(
            parkedShells: [], now: now, cap: 3, maxAge: day).isEmpty)
    }

    // MARK: - Helpers

    private func timed(_ id: String, room: String, at: TimeInterval,
                       agent: AgentKind = .claudeCode, file: String? = nil) -> Conversation {
        Conversation(id: id, agent: agent, roomPath: URL(fileURLWithPath: room),
                     sessionFile: URL(fileURLWithPath: file ?? room),
                     firstMessageAt: nil,
                     lastActivityAt: Date(timeIntervalSince1970: at),
                     previewText: nil)
    }

    private func persistedPane(_ id: String, agent: AgentKind = .claudeCode) -> PersistedPane {
        PersistedPane(conversationID: id, agentRaw: agent.rawValue,
                      roomPath: "/Users/x/dev/room", role: nil)
    }
}
