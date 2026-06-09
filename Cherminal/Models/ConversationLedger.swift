import Foundation

/// THE law for conversation identity — who owns which conversation, in which
/// pane, on which dtach socket. Every rule that used to be re-derived ad hoc
/// across the coordinator (find-open-pane preference, the serialization claim,
/// restore dedup, tray park/restore guards, the sweep keep-set) lives here
/// once, as pure functions over snapshots, so the invariants are enforced in
/// one place and unit-tested:
///
///   • one conversation id is OPEN in at most one pane
///   • two panes never serialize to the same id (they'd share a dtach socket
///     and mirror I/O)
///   • a master is never both an open pane and a tray cell
///   • the opened identity (base) outranks an adopted guess
///
/// The ledger doesn't own state — panes live in AppKit window lifecycles — it
/// owns the RULES. Callers snapshot facts, ask, then apply.
enum ConversationLedger {

    /// A pane's identity facts: the identity it was opened as (`base`, whose id
    /// is also the dtach socket key) and its current effective identity
    /// (`effective`, which adoption may have flipped).
    struct PaneFacts: Sendable {
        let paneID: UUID
        let base: Conversation
        let effective: Conversation

        init(paneID: UUID, base: Conversation, effective: Conversation) {
            self.paneID = paneID
            self.base = base
            self.effective = effective
        }
    }

    // MARK: - Who is conversation X right now?

    /// The open pane that "is" conversation `id` — PREFERRING a pane opened *as*
    /// that conversation (base.id — the identity actually chosen) over one that
    /// merely *adopted* it (a best-effort guess for a hand-launched Claude,
    /// which can be wrong when a room has several Claude conversations). Two
    /// full passes so the exact match always wins regardless of pane order.
    /// This is what makes "click conversation X" land on X.
    static func openPane(for id: String, panes: [PaneFacts]) -> UUID? {
        if let exact = panes.first(where: { $0.base.id == id }) { return exact.paneID }
        if let adopted = panes.first(where: { $0.effective.id == id }) { return adopted.paneID }
        return nil
    }

    /// Conversation ids open in some pane, by either identity. (The "is it
    /// open?" set used by park/restore guards.)
    static func openIDs(panes: [PaneFacts]) -> Set<String> {
        var out = Set<String>()
        for p in panes { out.insert(p.base.id); out.insert(p.effective.id) }
        return out
    }

    // MARK: - Serialization claim (save snapshot / quit persist)

    /// Resolve every open pane to a UNIQUE conversation for serialization. A
    /// conversation may be saved into ONE pane only — two panes can't resume
    /// the same agent (shared socket) — and restore's dedup would otherwise
    /// silently drop a pane, so a duplicate yields a unique *fallback*:
    ///
    ///   pass 1 — fixed-identity (agent) panes own their conversation id; they
    ///   were deliberately opened as that agent, so they win any collision
    ///   (a duplicate agent pane demotes to a fresh shell in its room).
    ///
    ///   pass 2 — shell panes take their freshly-detected agent (quit-time
    ///   detection) or their adopted conversation, unless that id is already
    ///   claimed, in which case they fall back to their unique base shell
    ///   identity.
    ///
    /// `makeShell` is injected so tests can use deterministic ids.
    static func claimIdentities(
        panes: [PaneFacts],
        detected: [UUID: Conversation] = [:],
        makeShell: (URL) -> Conversation = { Conversation.shellConversation(cwd: $0) }
    ) -> [UUID: Conversation] {
        var identity: [UUID: Conversation] = [:]
        var claimed = Set<String>()

        for pane in panes where pane.base.agent != .shell {
            if claimed.insert(pane.effective.id).inserted {
                identity[pane.paneID] = pane.effective
            } else {
                let shell = makeShell(pane.effective.roomPath)
                identity[pane.paneID] = shell
                claimed.insert(shell.id)
            }
        }
        for pane in panes where pane.base.agent == .shell {
            var convo = detected[pane.paneID] ?? pane.effective
            if !claimed.insert(convo.id).inserted {
                convo = pane.base
                // Base ids are unique per pane by construction; if even that
                // collides (corrupted state), mint a fresh shell rather than
                // ever letting two panes serialize to one id.
                if !claimed.insert(convo.id).inserted {
                    convo = makeShell(pane.base.roomPath)
                    claimed.insert(convo.id)
                }
            }
            identity[pane.paneID] = convo
        }
        return identity
    }

    // MARK: - Socket identity (persist + restore plan)

    /// The socket key to persist for a pane, when it carries information: a
    /// pane's dtach socket is fixed at spawn (keyed on `base.id`), so when a
    /// shell pane has ADOPTED a hand-launched agent, its claimed identity (the
    /// agent id) diverges from the socket actually holding the live process
    /// (the shell id). Persist the shell id so the sweep keeps that master and
    /// restore can reattach it. Everything else — sidebar-opened agents, plain
    /// shells, demoted duplicates (whose base socket belongs to ANOTHER pane's
    /// claim and must never be reattached here) — persists nil.
    static func socketToPersist(base: Conversation, claimed: Conversation) -> String? {
        (base.agent == .shell && claimed.id != base.id) ? base.id : nil
    }

    /// How a persisted pane comes back:
    ///   • a shell pane → a synthetic shell reusing its id (= its socket; the
    ///     wrap reattaches a surviving master, or cold-starts a fresh shell)
    ///   • an agent pane whose FOREIGN socket (a hand-launch's wrapped shell)
    ///     still has a live master → reattach that shell: the agent process is
    ///     alive inside it (the whole point of the wrap); the live-session
    ///     reconcile re-adopts the agent identity within a tick
    ///   • otherwise → cold `--resume` keyed on the conversation id (the
    ///     master died — Mac restart — or there never was a foreign socket)
    enum RestorePlan: Equatable {
        case shell(id: String)
        case attachLiveShell(socketID: String)
        case resumeAgent

        /// True when this pane reattaches a live master holding an agent the
        /// pane's identity doesn't reflect yet (adoption will flip it).
        var isLiveAttach: Bool {
            if case .attachLiveShell = self { return true }
            return false
        }
    }

    static func restorePlan(
        for pane: PersistedPane,
        masterAlive: (String) -> Bool
    ) -> RestorePlan {
        if pane.agentRaw == AgentKind.shell.rawValue {
            return .shell(id: pane.conversationID)
        }
        if let socket = pane.socketID, socket != pane.conversationID, masterAlive(socket) {
            return .attachLiveShell(socketID: socket)
        }
        return .resumeAgent
    }

    // MARK: - Restore dedup

    /// Filter saved workspaces so each conversation id restores into at most
    /// ONE pane — across all workspaces — and skip ids in `alreadyOpen` (panes
    /// live right now), which makes restore idempotent: re-running it over an
    /// existing session can only add what's missing, never duplicate a socket.
    /// The result is aligned 1:1 with the input (a workspace whose panes were
    /// all dropped comes back empty) so callers can act on the originals —
    /// e.g. focus an already-open tab instead of opening nothing.
    static func dedupeForRestore(
        _ workspaces: [PersistedWorkspace],
        alreadyOpen: Set<String> = []
    ) -> [PersistedWorkspace] {
        var seen = alreadyOpen
        return workspaces.map { workspace in
            var filtered = workspace
            filtered.panes = workspace.panes.filter { seen.insert($0.conversationID).inserted }
            return filtered
        }
    }

    // MARK: - Tray (park / restore) guards

    /// May `convo` park into the tray when its pane closes?
    ///   • only if there's a live master to keep — agents always have one; a
    ///     shell only if it was dtach-wrapped at spawn (checked by ACTUAL
    ///     socket liveness, not the current preference — the user may have
    ///     toggled persistentSessions off after the pane spawned)
    ///   • never while that conversation is still open in some pane (the open
    ///     pane owns the master)
    ///   • never twice (one cell per master)
    /// `masterAlive` is consulted lazily — only for non-agents.
    static func canPark(
        _ convo: Conversation,
        openPanes: [PaneFacts],
        parked: [DetachedAgent],
        masterAlive: (String) -> Bool
    ) -> Bool {
        let isAgent = convo.agent == .claudeCode || convo.agent == .codex
        guard isAgent || masterAlive(convo.id) else { return false }
        guard !openIDs(panes: openPanes).contains(convo.id) else { return false }
        guard !parked.contains(where: { $0.id == convo.id }) else { return false }
        return true
    }

    /// Which saved tray entries may restore at launch: master still alive, and
    /// not already open as a pane (restoreSession ran first — one master must
    /// not be both a tab and a tray cell).
    static func restorableTray(
        saved: [PersistedTab],
        openPanes: [PaneFacts],
        masterAlive: (String) -> Bool
    ) -> [PersistedTab] {
        let open = openIDs(panes: openPanes)
        return saved.filter { masterAlive($0.conversationID) && !open.contains($0.conversationID) }
    }

    // MARK: - Launch sweep

    /// The socket ids the launch sweep must NOT reap: everything a restored
    /// tab or a restored tray cell will reattach — including a hand-launched
    /// agent's FOREIGN socket (its wrapped shell's master, holding the live
    /// agent; see socketToPersist). Anything else holding a socket is a crash
    /// orphan (it would run forgotten) or a stale socket.
    static func sweepKeepSet(
        savedWorkspaces: [PersistedWorkspace],
        savedTray: [PersistedTab]
    ) -> Set<String> {
        let panes = savedWorkspaces.flatMap { $0.panes }
        return Set(panes.map(\.conversationID))
            .union(panes.compactMap(\.socketID))
            .union(savedTray.map { $0.conversationID })
    }
}
