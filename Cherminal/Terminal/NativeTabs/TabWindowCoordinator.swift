import AppKit
import SwiftUI
import GhosttyKit
import os

extension Notification.Name {
    /// Posted by a Ghostty surface the moment it becomes its window's first
    /// responder, so the coordinator can keep `activePaneID` (the visual focus)
    /// locked to the surface that actually has the keyboard.
    static let chmSurfaceDidBecomeFirstResponder = Notification.Name("chm.surfaceDidBecomeFirstResponder")
}

/// Owns the native macOS tab group: one `NSWindow` per conversation, joined
/// via `addTabbedWindow`, each hosting the full 3-pane SwiftUI. Replaces the
/// single-window custom tab bar + surface deck. Surfaces live for the
/// lifetime of their window, so background tabs stay alive natively.
@MainActor
final class TabWindowCoordinator: ObservableObject {
    private static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "tabwindows")

    private let registry: ConversationRegistry
    private let ghostty: Ghostty.App
    private let bookmarks: BookmarksManager

    /// Ordered, and the strong refs that keep the windows alive. A window's
    /// controller is dropped here on close, which deallocates the window and
    /// SIGHUPs its PTY.
    private var controllers: [TerminalTabWindowController] = [] {
        didSet {
            tabCount = controllers.count
            schedulePersist()   // keep the restore snapshot current on every open/close
        }
    }

    /// Published so bookmark UI can reflect how many tabs would be saved.
    @Published private(set) var tabCount: Int = 0 {
        didSet { updateLinkPolling() }
    }

    /// Conversation ids currently running live in a tab (hand-launched agents
    /// or resumed sessions). The sidebar reads this to show a live indicator.
    @Published private(set) var liveConversationIDs: Set<String> = []

    /// Conversations whose agent finished its turn and is waiting on you —
    /// detected by reading the session JSONL (no bell, no hooks; see TurnState).
    /// The sidebar shows a calm blue "your turn" light for these; it clears the
    /// moment you focus the tab.
    @Published private(set) var awaitingTurnIDs: Set<String> = []

    /// Per-conversation byte offset of the turn you've already seen (the session
    /// file's size when you last focused its tab). A completed turn only lights
    /// up when the file has grown past this — so re-focusing a tab you've
    /// already read doesn't re-trigger, and only a genuinely *new* turn does.
    private var seenTurnSize: [String: UInt64] = [:]

    /// Agents detached into the side rail: their pane was closed but their
    /// `dtach` master is still alive, so they keep running off-screen for ≈0
    /// memory. The tray UI renders one cell per entry, lit by `state`.
    @Published private(set) var detachedAgents: [DetachedAgent] = [] {
        didSet {
            updateLinkPolling()   // keep the watcher/poll alive while the tray has agents
            persistDetached()     // survive relaunch (reconciled against live masters)
        }
    }

    /// Set the instant the app starts quitting. Closing a window during normal
    /// use detaches its agents to the tray; closing windows during *termination*
    /// must not — the masters survive anyway and session restore reattaches them
    /// into tabs on next launch, so tray-on-quit would just duplicate them.
    private var isTerminating = false
    func beginTermination() { isTerminating = true }

    /// Polls the live-session linker while any tab is open.
    private var linkTimer: Timer?
    /// Drives the "your turn" light off FSEvents — the OS tells us the instant
    /// an agent writes its turn-ending line, so there's no polling: idle costs
    /// nothing and the light follows turn completion in ~0.3s. (The 8s reconcile
    /// still handles the agent-exited case, where no write occurs.)
    private var awaitWatcher: FilesystemWatcher?
    /// Reentrancy guard: an `lsof` poll can outlast the 3s interval, so the
    /// next tick must not start a second overlapping reconcile (which would
    /// double-write tab identities / the live set).
    private var reconciling = false

    /// Notification observer tokens, removed in deinit (harmless today as a
    /// singleton, but correct if this ever stops being one).
    private var observers: [any NSObjectProtocol] = []

    /// The "no tabs open" home window, shown when the last conversation tab
    /// closes (instead of quitting) and hidden again the moment a tab opens.
    /// Created lazily and reused.
    private var placeholder: PlaceholderWindowController?

    init(registry: ConversationRegistry, ghostty: Ghostty.App, bookmarks: BookmarksManager) {
        self.registry = registry
        self.ghostty = ghostty
        self.bookmarks = bookmarks

        // "Your turn" attention light clears the instant you focus a tab; it's
        // *set* by the session-file poll in reconcileLiveSessions (no bell).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.clearAwaiting(forWindow: note.object as? NSWindow) }
        })

        // Keep the active-pane highlight locked to the surface that actually holds
        // the keyboard: whenever any surface becomes first responder (click, ⌘`,
        // tab switch, spawn) reflect it into its workspace's activePaneID. This is
        // the source of truth that prevents "clicked one pane, typing into another".
        observers.append(NotificationCenter.default.addObserver(
            forName: .chmSurfaceDidBecomeFirstResponder, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.syncActivePane(toFocused: note.object as? Ghostty.SurfaceView) }
        })

        // The 8s live-session reconcile is paused while the app is backgrounded
        // (energy); refresh once the moment it comes forward so live badges /
        // "your turn" lights are current when you look.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reconcileLiveSessions() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Attention light ("your turn")

    /// You just focused a tab: drop its light and remember how far you've read,
    /// so re-focusing won't relight until the agent completes a *new* turn.
    private func clearAwaiting(forWindow window: NSWindow?) {
        guard let window,
              let controller = controllers.first(where: { $0.window === window }) else { return }
        let id = controller.conversation.id
        awaitingTurnIDs.remove(id)
        seenTurnSize[id] = Self.fileSize(controller.conversation.sessionFile)
    }

    /// Recompute which live agent tabs are awaiting you, from their session
    /// files. Called at the tail of each live-session reconcile (same 8s
    /// cadence), so the light follows turn completion without any bell.
    private func updateAwaiting(live: Set<String>) {
        var awaiting = awaitingTurnIDs
        for controller in controllers {
            let isKey = controller.window?.isKeyWindow == true
            for pane in controller.workspace.panes {
                let convo = pane.conversation
                let id = convo.id
                guard live.contains(id), convo.agent == .claudeCode || convo.agent == .codex else { continue }
                let reading = TurnState.read(sessionFile: convo.sessionFile, agent: convo.agent)
                // "Viewed" = its window is key AND it's the active pane.
                if isKey && controller.workspace.activePaneID == pane.id {
                    seenTurnSize[id] = reading.size
                    awaiting.remove(id)
                } else if reading.awaitingUser && reading.size > (seenTurnSize[id] ?? 0) {
                    awaiting.insert(id)        // a new completed turn you haven't seen
                } else if !reading.awaitingUser {
                    awaiting.remove(id)        // back to working
                }
            }
        }
        // A pane that closed or whose agent exited is no longer awaiting.
        awaiting = awaiting.filter { live.contains($0) }
        if awaitingTurnIDs != awaiting { awaitingTurnIDs = awaiting }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Open / focus

    /// Open `conversation` in a new native tab, or select its existing tab.
    @discardableResult
    func openOrFocus(_ conversation: Conversation) -> TerminalTabWindowController? {
        clog("tabs", "openOrFocus id=\(conversation.id) agent=\(conversation.agent.rawValue) room=\(conversation.roomName) path=\(conversation.roomPath.path)")
        if let existing = controllers.first(where: { $0.conversation.id == conversation.id }) {
            clog("tabs", "→ focus existing tab")
            select(existing)
            return existing
        }

        guard ghostty.app != nil else {
            clog("tabs", "→ ABORT: ghostty app not ready")
            Self.logger.error("openOrFocus before ghostty ready")
            return nil
        }

        let controller = TerminalTabWindowController(
            conversation: conversation,
            registry: registry,
            ghostty: ghostty,
            bookmarks: bookmarks,
            coordinator: self
        )

        // Join the existing tab group, or stand alone as the first tab.
        if let anchor = controllers.last?.window ?? controllers.first?.window,
           let newWindow = controller.window {
            anchor.addTabbedWindow(newWindow, ordered: .above)
        }
        controllers.append(controller)
        select(controller)
        hidePlaceholder()   // a tab is open now; the home window steps aside

        // Lay out the panes now, then spawn the surface on the next runloop —
        // once the sidebar + inspector have claimed their widths and the
        // terminal pane is at its real size. The shell (and its fastfetch
        // banner, which can't reflow) then start at the correct width instead
        // of into the momentarily-squished pane.
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        spawnSurface(for: controller.workspace.panes[0], in: controller)
        return controller
    }

    /// Spawn a pane's Ghostty surface. Config is built OFF the main thread
    /// (BinaryResolver can block ~3s on a cold launch); the SurfaceView itself
    /// is created on main (libghostty requires it), re-checking the pane is
    /// still live. Shared by openOrFocus and addPane.
    private func spawnSurface(for pane: Pane, in controller: TerminalTabWindowController) {
        // Bail if a surface exists OR a build is already in flight. The config
        // build is ~3s async during which surfaceView stays nil, so guarding on
        // surfaceView alone would let a re-entrant call kick off a redundant
        // build; lifecycleState is the value actually set to mark it in-flight.
        guard pane.surfaceView == nil, pane.lifecycleState != .spawning else { return }
        pane.lifecycleState = .spawning
        let conversation = pane.conversation
        Task.detached(priority: .userInitiated) {
            let config = TerminalCommand.surfaceConfig(for: conversation)
            await MainActor.run { [weak self, weak controller, weak pane] in
                guard let self, let controller, let pane,
                      self.controllers.contains(where: { $0 === controller }),
                      controller.workspace.panes.contains(where: { $0 === pane }),
                      pane.surfaceView == nil,
                      let app = self.ghostty.app else { return }
                clog("tabs", "spawn surface id=\(conversation.id) cwd=\(config.workingDirectory ?? "nil") cmd=\(config.command ?? "default-shell")")
                pane.surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
                pane.lifecycleState = .live
                pane.lastActiveAt = Date()
                // Make the freshly-spawned surface the keyboard first responder so
                // a new / restored / split tab is typeable (and ⌘V works) without a
                // click. Only when it's the active pane — a background split must not
                // steal focus. moveFocus retries until the new NSView attaches to its
                // window; setting first responder never changes the *key* window, so a
                // surface spawned in a non-key tab simply becomes that tab's responder
                // for when you switch to it.
                if controller.workspace.activePaneID == pane.id {
                    Ghostty.moveFocus(to: pane.surfaceView!)
                }
                // This conversation is back on screen — drop any rail cell for it
                // (covers reattach from the sidebar / "Open as Pane", not just the
                // rail's own click). The dtach socket is shared, so the surface
                // reattaches the same master.
                self.detachedAgents.removeAll { $0.id == conversation.id }
                clog("tabs", "spawn surface ok id=\(conversation.id) pane=\(pane.id)")
                // No cap: panes you open stay live (you split to *see* them).
                // Each surface is mostly the shared GPU baseline; marginal cost
                // is modest. Heavy all-agent grids can get RAM-hungry — that's
                // the honest trade for keeping every pane live.
            }
        }
    }

    // MARK: - Pane management (the grid)

    /// The window receiving pane commands — the key window, else the last.
    private var activeController: TerminalTabWindowController? {
        if let key = NSApp.keyWindow, let m = controllers.first(where: { $0.window === key }) { return m }
        return controllers.last
    }

    /// Split the active window: add a shell pane in the active pane's room.
    func addPaneToActiveWindow() {
        guard let controller = activeController else { openFreshShell(); return }
        addPane(Conversation.shellConversation(cwd: controller.holder.conversation.roomPath), to: controller)
    }

    /// Open a specific conversation as a pane in the active window's grid (the
    /// sidebar "Open as Pane"). No active window → opens it as a tab instead.
    /// Dedups like `openOrFocus`: if this conversation is already live in some
    /// pane, focus it rather than spawning a second pane on the same dtach socket
    /// (which would mirror I/O and confuse pid→id bookkeeping).
    func openConversationInPane(_ conversation: Conversation) {
        if focusExistingPane(conversationID: conversation.id) { return }
        guard let controller = activeController else { openOrFocus(conversation); return }
        addPane(conversation, to: controller)
    }

    /// Find a live pane already running `conversationID` (by effective or opened
    /// identity), focus its window + pane, and return true. Used to dedup
    /// "Open as Pane" / rail reattach against an already-open conversation.
    @discardableResult
    private func focusExistingPane(conversationID: String) -> Bool {
        for controller in controllers {
            if let pane = controller.workspace.panes.first(where: {
                $0.conversation.id == conversationID || $0.base.id == conversationID
            }) {
                select(controller)
                focusPane(pane, in: controller.workspace)
                return true
            }
        }
        return false
    }

    private func addPane(_ conversation: Conversation, to controller: TerminalTabWindowController) {
        guard controller.workspace.panes.count < 16 else { return }
        let pane = Pane(conversation: conversation)
        controller.workspace.addPane(pane)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        spawnSurface(for: pane, in: controller)
        schedulePersist()
    }

    /// Close the active pane; if it's the last one, close the window. An agent
    /// pane is *detached* (parked in the rail, master kept alive) rather than
    /// killed; a shell pane just closes.
    func closeActivePane() {
        guard let controller = activeController else { return }
        let ws = controller.workspace
        guard ws.panes.count > 1, let active = ws.activePane else {
            controller.window?.performClose(nil)   // last pane → window close (handles detach)
            return
        }
        let parked = active.base       // capture before teardown; defer the tray write
        ws.removePane(id: active.id)   // pane deinit drops its surface (SIGHUP to the dtach client)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.detachToTray(parked) }
        schedulePersist()
    }

    func focusNextPane() {
        guard let ws = activeController?.workspace else { return }
        ws.focusNext()
        if let pane = ws.activePane { focusPane(pane, in: ws) }
    }

    /// Activate a pane (on click or ⌘`). Sets the active-pane border AND moves
    /// the AppKit first responder to the pane's surface — these must stay in
    /// lockstep. The surface's own click-to-focus transfer is defeated in a grid:
    /// it only fires when `window.contentView.hitTest` returns the surface, but
    /// our SwiftUI overlays (contentShape/border/badge) sit above it, so the
    /// hit-test returns a SwiftUI layer and the surface never takes focus. Moving
    /// the responder here is what keeps typing going to the pane you clicked.
    func focusPane(_ pane: Pane, in workspace: Workspace) {
        // Keep the @Published activePaneID write idempotent — the click
        // recognizer (mouse-down DragGesture) fires on every drag-change, and we
        // don't want to re-publish (re-render) on each one.
        if workspace.activePaneID != pane.id {
            workspace.activePaneID = pane.id
            pane.lastActiveAt = Date()
        }
        // Always route through moveFocus, even when this surface is ALREADY first
        // responder: a click must refresh the surface's focus "recency ticket"
        // (focusAppliedSeq) so a still-pending spawn/tab retry for another
        // just-opened pane (with a newer ticket) can't later steal focus from the
        // pane you deliberately clicked. Cheap when already focused —
        // makeFirstResponder is a no-op but still returns true (so the ticket
        // updates), and the ticket fields aren't @Published (no re-render). It
        // also retries with backoff until a just-spawned surface attaches.
        if let surface = pane.surfaceView {
            Ghostty.moveFocus(to: surface)
        }
    }

    /// Reflect an AppKit focus change into the owning workspace's activePaneID,
    /// so the visual active pane (border/dim) stays locked to the surface that
    /// holds the keyboard. Posted by SurfaceView.becomeFirstResponder — the
    /// single source of truth that prevents "clicked one pane, typing into another".
    private func syncActivePane(toFocused surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        for controller in controllers {
            guard let pane = controller.workspace.panes.first(where: { $0.surfaceView === surface })
            else { continue }
            if controller.workspace.activePaneID != pane.id {
                controller.workspace.activePaneID = pane.id
                pane.lastActiveAt = Date()
            }
            return
        }
    }

    /// Open a bare shell tab. cwd defaults to the active tab's room, else $HOME.
    func openFreshShell(cwd explicitCWD: URL? = nil) {
        let cwd = explicitCWD
            ?? activeConversation?.roomPath
            ?? URL(fileURLWithPath: NSHomeDirectory())
        openOrFocus(Conversation.shellConversation(cwd: cwd))
    }

    // MARK: - Detach tray ("minesweeper" rail)

    /// Park an agent pane in the side rail instead of ending it: its `dtach`
    /// master outlives the surface teardown, so it keeps running off-screen.
    /// Only resumed agents are dtach-wrapped (see TerminalCommand), so only a
    /// pane opened *as* an agent can detach; bare shells (and agents
    /// hand-launched inside a shell pane, which run raw) just close. No-op if
    /// it's already parked.
    /// Takes the opened identity (a value type) so callers can capture it and
    /// defer this off the surface-teardown runloop — see callers. Mutating the
    /// `@Published` tray + spawning tasks *during* a window/pane close (i.e.
    /// mid Metal-surface dealloc) is a libghostty fault risk; deferring avoids it.
    private func detachToTray(_ convo: Conversation) {
        guard convo.agent == .claudeCode || convo.agent == .codex else { return }
        guard !detachedAgents.contains(where: { $0.id == convo.id }) else { return }
        detachedAgents.append(DetachedAgent(conversation: convo))
        clog("tabs", "detached agent \(convo.id) → tray")
        refreshDetachedStates()
    }

    /// Pull a parked agent back onto the screen. Opening its conversation
    /// respawns with the same dtach socket, so `dtach -A` reattaches the live
    /// master (or, if it died, cold-resumes the conversation). Drops it from the
    /// rail either way.
    func reattach(_ agent: DetachedAgent) {
        detachedAgents.removeAll { $0.id == agent.id }
        openConversationInPane(agent.conversation)
    }

    /// Reattach into a fresh tab instead of the active grid.
    func reattachAsTab(_ agent: DetachedAgent) {
        detachedAgents.removeAll { $0.id == agent.id }
        openOrFocus(agent.conversation)
    }

    /// End a parked agent for good: SIGTERM its master and drop the cell.
    func killDetached(_ agent: DetachedAgent) {
        Dtach.kill(id: agent.id)
        detachedAgents.removeAll { $0.id == agent.id }
        clog("tabs", "killed detached agent \(agent.id)")
    }

    /// Reentrancy guard + last pgrep time. FSEvents can fire many times a second
    /// while an agent works; without these, each fire would spawn one `pgrep`
    /// Process per parked agent — a process storm. The guard collapses
    /// overlapping refreshes; liveness (pgrep) is rate-limited to ~4s while the
    /// cheap JSONL tail read still runs every time.
    private var detachedRefreshing = false
    private var lastLivenessCheck = Date.distantPast

    /// Recompute each parked agent's cell state off the main thread — a cheap
    /// JSONL tail read every time, master liveness (pgrep) at most every ~4s —
    /// then publish any changes. Driven by the FSEvents callback + 8s reconcile.
    private func refreshDetachedStates() {
        guard !detachedAgents.isEmpty, !detachedRefreshing else { return }
        detachedRefreshing = true
        let agents = detachedAgents
        let checkLiveness = Date().timeIntervalSince(lastLivenessCheck) > 4
        Task.detached(priority: .utility) {
            var next: [String: DetachState] = [:]
            for a in agents {
                if checkLiveness && !Dtach.isMasterAlive(id: a.id) { next[a.id] = .dead; continue }
                let reading = TurnState.read(sessionFile: a.conversation.sessionFile, agent: a.conversation.agent)
                next[a.id] = reading.awaitingUser ? .attention : .working
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.detachedRefreshing = false
                if checkLiveness { self.lastLivenessCheck = Date() }
                let updated = self.detachedAgents.map { agent -> DetachedAgent in
                    guard let s = next[agent.id] else { return agent }
                    // Don't resurrect a known-dead cell from a stale file read on
                    // a tick where we skipped the liveness check.
                    let resolved: DetachState = (!checkLiveness && agent.state == .dead) ? .dead : s
                    guard resolved != agent.state else { return agent }
                    var copy = agent; copy.state = resolved; return copy
                }
                if updated != self.detachedAgents { self.detachedAgents = updated }
            }
        }
    }

    // MARK: - Ports

    /// Maps each open tab's foreground process pid → its conversation id, so
    /// the port watcher can attribute a dev server (a descendant of that
    /// process) to the conversation that spawned it.
    func tabForegroundPIDs() -> [Int32: String] {
        var out: [Int32: String] = [:]
        for c in controllers {
            for pane in c.workspace.panes {
                guard let surface = pane.surfaceView?.surface else { continue }
                let pid = ghostty_surface_foreground_pid(surface)
                if pid > 0 { out[Int32(pid)] = pane.conversation.id }
            }
        }
        return out
    }

    // MARK: - Bookmarks

    /// Snapshot of every open tab, for saving as a bookmark group. Resolves
    /// each tab to what it's *actually running right now* (synchronous detect),
    /// so a hand-launched `claude`/`codex` is saved as that conversation even
    /// if the periodic adoption poll hasn't flipped the tab's identity yet —
    /// otherwise the group would store a bare shell and reopen as one.
    func snapshot() -> [PersistedTab] {
        let detected = detectLiveConversations()
        // Dedup by conversation id: two shell tabs in the same room can both
        // resolve to the same agent session, and a group must never store two
        // PersistedTab with the same id (their Identifiable id == conversationID).
        var seen = Set<String>()
        return controllers.compactMap { c in
            let convo = detected[ObjectIdentifier(c)] ?? c.conversation
            guard seen.insert(convo.id).inserted else { return nil }
            return PersistedTab(
                conversationID: convo.id,
                agentRaw: convo.agent.rawValue,
                roomPath: convo.roomPath.path
            )
        }
    }

    // MARK: - Persisted tabs (bookmarks + session restore)

    private static let lastSessionKey = "cherminal.lastSession"

    /// Open a saved list of tabs in order, resolving each to its live
    /// conversation when the session still exists, else a shell in the same
    /// room. Shared by session restore and bookmark groups so both honour the
    /// same dedup + fallback rules. Resolves agents against the registry, so
    /// the cache snapshot must be loaded first (else the agent's sessionFile is
    /// unknown and the context gauge can't read it).
    func openPersistedTabs(_ tabs: [PersistedTab]) {
        for persisted in tabs {
            let convo: Conversation
            if persisted.agentRaw == AgentKind.shell.rawValue {
                // Reuse the persisted id so reopening focuses the same tab
                // instead of spawning a fresh duplicate.
                convo = Conversation.shellConversation(
                    cwd: URL(fileURLWithPath: persisted.roomPath),
                    id: persisted.conversationID)
            } else if let real = registry.conversation(id: persisted.conversationID) {
                convo = real
            } else {
                // The agent session is gone (file deleted / reconciled away).
                // Reopen as a shell in the same room rather than dropping the
                // tab. Fresh id so a stale agent id can't collide with a future
                // real conversation.
                convo = Conversation.shellConversation(cwd: URL(fileURLWithPath: persisted.roomPath))
            }
            openOrFocus(convo)
        }
    }

    /// Snapshot the open tabs to disk so the next launch can reopen them. Uses
    /// the precise live detect (via `snapshot()`) so a hand-launched agent is
    /// saved as that agent, not the bare shell it started as. Called on quit.
    func persistSession() {
        let tabs = snapshot()
        // Never clobber the continuous save with an empty set. An empty result
        // at terminate is almost always teardown — macOS sends SIGTERM on
        // restart/logout and AppKit can close the windows (emptying controllers)
        // *before* this runs, which previously wiped the saved session and lost
        // every tab on a Mac restart. The debounced persistSessionLight already
        // writes [] correctly the moment you genuinely close everything, so
        // skipping here only protects a good snapshot from a teardown race.
        guard !tabs.isEmpty else {
            clog("tabs", "terminate snapshot empty — keeping the continuous save")
            return
        }
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastSessionKey)
        clog("tabs", "persisted \(tabs.count) tab(s) for next launch")
    }

    /// Continuous, debounced persistence — the robustness fix. `persistSession()`
    /// only ran on a clean quit, so a Mac restart / crash / force-quit / quitting
    /// by closing the last tab all left a stale-or-empty snapshot and restored
    /// nothing. This keeps the saved set current after every change, so any exit
    /// path restores. No lsof (unlike snapshot()): it trusts each tab's current
    /// effective conversation, which the 8s reconcile already keeps adopted.
    private var persistDebounce: DispatchWorkItem?

    private func schedulePersist() {
        persistDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistSessionLight() }
        persistDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func persistSessionLight() {
        var seen = Set<String>()
        let tabs: [PersistedTab] = controllers.compactMap { controller in
            let convo = controller.conversation
            guard seen.insert(convo.id).inserted else { return nil }
            return PersistedTab(conversationID: convo.id,
                                agentRaw: convo.agent.rawValue,
                                roomPath: convo.roomPath.path)
        }
        // Do NOT clobber the saved set with [] just because every tab closed.
        // Closing the last tab (→ placeholder) used to wipe the session, so a
        // later quit restored nothing. We keep the last non-empty snapshot; the
        // quit path is the only thing that *clears* it, and only when the user
        // chooses "Don't Reopen" (see CherminalAppDelegate / reopenChoice).
        guard !tabs.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastSessionKey)
    }

    /// Forget the saved session so the next launch starts fresh. Called when the
    /// user answers "Don't Reopen" at quit.
    func clearSavedSession() {
        UserDefaults.standard.removeObject(forKey: Self.lastSessionKey)
    }

    // MARK: - Reopen-on-launch preference ("save windows"-style)

    /// Whether to reopen the saved tabs on next launch. `ask` shows the prompt
    /// at quit; the user can pick "Don't ask again" to lock in reopen/dontReopen.
    enum ReopenChoice: String { case ask, reopen, dontReopen }
    private static let reopenChoiceKey = "cherminal.reopenChoice"

    var reopenChoice: ReopenChoice {
        ReopenChoice(rawValue: UserDefaults.standard.string(forKey: Self.reopenChoiceKey) ?? "") ?? .ask
    }
    func setReopenChoice(_ choice: ReopenChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: Self.reopenChoiceKey)
    }

    /// The tabs persisted by the last run, decoded but not opened — lets the
    /// launch path decide synchronously whether a restore is even needed.
    func savedSessionTabs() -> [PersistedTab] {
        guard let data = UserDefaults.standard.data(forKey: Self.lastSessionKey),
              let tabs = try? JSONDecoder().decode([PersistedTab].self, from: data)
        else { return [] }
        return tabs
    }

    /// Reopen the tabs saved by the last run. Returns false (having opened
    /// nothing) when there's no saved session, so the caller falls back to a
    /// fresh shell.
    @discardableResult
    func restoreSession() -> Bool {
        let tabs = savedSessionTabs()
        guard !tabs.isEmpty else { return false }
        clog("tabs", "restoring \(tabs.count) tab(s) from last session")
        openPersistedTabs(tabs)
        return !controllers.isEmpty
    }

    // MARK: - Detach tray persistence + launch sweep

    private static let detachedKey = "cherminal.detachedAgents"

    /// Persist the parked agents (id/agent/room) so the rail survives relaunch.
    /// Reconciled against live masters at launch (restoreDetachedAgents), so a
    /// master that died while the app was off is dropped, not shown as alive.
    private func persistDetached() {
        let items = detachedAgents.map {
            PersistedTab(conversationID: $0.id,
                         agentRaw: $0.conversation.agent.rawValue,
                         roomPath: $0.conversation.roomPath.path)
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.detachedKey)
    }

    /// The parked agents persisted by the last run, decoded but not resolved.
    func savedDetached() -> [PersistedTab] {
        guard let data = UserDefaults.standard.data(forKey: Self.detachedKey),
              let items = try? JSONDecoder().decode([PersistedTab].self, from: data)
        else { return [] }
        return items
    }

    /// Rebuild the rail from the saved set, keeping only those whose `dtach`
    /// master is still alive (resolving each id against the registry, so the
    /// cache snapshot must be loaded first). Dead ones are dropped.
    func restoreDetachedAgents() {
        let saved = savedDetached()
        guard !saved.isEmpty else { return }
        var restored: [DetachedAgent] = []
        for it in saved where it.agentRaw != AgentKind.shell.rawValue {
            guard Dtach.isMasterAlive(id: it.conversationID),
                  let convo = registry.conversation(id: it.conversationID) else { continue }
            restored.append(DetachedAgent(conversation: convo))
        }
        if !restored.isEmpty { detachedAgents = restored }
        refreshDetachedStates()
    }

    /// Reap dtach masters that nothing will reattach. At launch, the only
    /// sockets we keep are those a restored tab or a restored tray cell will
    /// reattach; any other live master is an orphan from a crash (it'd run
    /// forgotten), and any dead socket is stale — both get killed (socket
    /// removed). Run once, before restore, so nothing lingers invisibly.
    func sweepDtachSockets() {
        let keep = Set(savedSessionTabs().map { $0.conversationID })
            .union(savedDetached().map { $0.conversationID })
        for id in Dtach.knownSocketIDs() where !keep.contains(id) {
            Dtach.kill(id: id)
            clog("tabs", "swept orphan dtach socket \(id)")
        }
    }

    // MARK: - Active

    var isEmpty: Bool { controllers.isEmpty }

    var activeConversation: Conversation? {
        if let key = NSApp.keyWindow,
           let match = controllers.first(where: { $0.window === key }) {
            return match.conversation
        }
        return controllers.last?.conversation
    }

    // MARK: - Lifecycle

    /// Called from the window controller's `windowWillClose`. Dropping the
    /// strong ref deallocates the window + surface.
    func windowClosed(_ controller: TerminalTabWindowController) {
        // Closing a window during normal use parks its agent panes in the tray
        // (masters survive); during app termination it must not (restore
        // reattaches them into tabs next launch — see beginTermination).
        // Capture identities now but defer the tray write to the next runloop:
        // mutating @Published state mid window-close (during surface dealloc)
        // faults libghostty.
        // Park the closed window's agents in the tray — but NOT when the app is
        // quitting (restore reattaches them as tabs next launch; parking them
        // would also let one survive a "Don't Reopen"). Closing the last window
        // routes to quit, yet windowClosed fires BEFORE applicationShouldTerminate
        // can call beginTermination, so isTerminating is still false right here.
        // We re-check it inside the deferred block: on a real quit, beginTermination
        // runs synchronously during this same close event — before the next-runloop
        // block executes — so it skips. If the app is NOT terminating (e.g. another
        // window like Settings keeps it alive, or it's not the last window), the
        // re-check still parks the agent so it never runs invisibly. The defer is
        // also required because mutating @Published state mid window-close (during
        // surface dealloc) faults libghostty.
        if !isTerminating {
            let parked = controller.workspace.panes.map(\.base)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTerminating else { return }   // quit won the race
                parked.forEach { self.detachToTray($0) }
            }
        }
        controllers.removeAll { $0 === controller }
        clog("tabs", "window closed (surfaces freed)")
        // The attention light is insert-on-bell / remove-on-focus; a tab that
        // closes while flagged would leak its id forever (clearAwaiting only
        // fires for still-registered windows). Clear both the effective and
        // base identity so a shell↔agent flip can't strand it either.
        awaitingTurnIDs.remove(controller.conversation.id)
        awaitingTurnIDs.remove(controller.base.id)
        // Prune the seen-offset map too, else it grows unbounded over a long
        // session (entries are written per conversation but were never removed).
        seenTurnSize.removeValue(forKey: controller.conversation.id)
        seenTurnSize.removeValue(forKey: controller.base.id)

        // Last tab gone → let the app quit like normal software (see
        // applicationShouldTerminateAfterLastWindowClosed → true, which routes to
        // the reopen prompt). We deliberately do NOT pop the placeholder here: it
        // kept the app alive after closing the last tab, which is exactly the
        // "close, then a home window appears, then close again" double-X that felt
        // broken. The placeholder window/controller still exists for explicit use,
        // it's just not forced open on close.
    }

    // MARK: - Placeholder (no tabs open)

    private func showPlaceholder(near frame: NSRect?) {
        let pc = placeholder ?? PlaceholderWindowController(
            registry: registry, ghostty: ghostty, bookmarks: bookmarks, coordinator: self)
        placeholder = pc
        if let frame, let window = pc.window {
            window.setFrame(frame, display: false)
        } else {
            pc.window?.center()
        }
        pc.window?.makeKeyAndOrderFront(nil)
    }

    private func hidePlaceholder() {
        placeholder?.window?.orderOut(nil)
    }

    private func select(_ controller: TerminalTabWindowController) {
        guard let window = controller.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.tabGroup?.selectedWindow = window
        // Put keyboard focus on the active pane's surface. AppKit only restores a
        // window's *prior* first responder when it becomes key — a tab you've
        // never clicked into has none, so without this a sidebar-opened or
        // re-focused tab couldn't receive typing/paste until clicked. (On the
        // very first open the surface is still nil here; spawnSurface focuses it.)
        focusActivePaneSurface(in: controller)
    }

    /// Move keyboard focus to a window's active-pane surface. Called on every
    /// path that brings a tab to the front (open, select, tab switch) so the
    /// terminal is always input-ready without a click. No-op while the surface
    /// is still spawning (nil) — spawnSurface handles that case.
    private func focusActivePaneSurface(in controller: TerminalTabWindowController) {
        guard let surface = controller.workspace.activePane?.surfaceView else { return }
        Ghostty.moveFocus(to: surface)
    }

    private func focusActivePaneSurface(inWindow window: NSWindow) {
        guard let controller = controllers.first(where: { $0.window === window }) else { return }
        focusActivePaneSurface(in: controller)
    }

    // MARK: - Tab navigation (menu shortcuts)

    /// The shared tab group, taken from the frontmost Cherminal window. Using
    /// the live group (not the `controllers` array) honours the user's visible
    /// tab order even after they drag-reorder tabs.
    private func activeTabGroup() -> NSWindowTabGroup? {
        (NSApp.keyWindow ?? controllers.last?.window)?.tabGroup
    }

    /// Select the Nth tab in visible order. 1–8 are literal; 9 jumps to the
    /// last tab (browser convention) so ⌘9 always lands on the rightmost.
    func selectTab(number: Int) {
        guard let group = activeTabGroup() else { return }
        let windows = group.windows
        guard !windows.isEmpty else { return }
        let idx = number >= 9 ? windows.count - 1 : number - 1
        guard idx >= 0, idx < windows.count else { return }
        group.selectedWindow = windows[idx]
        windows[idx].makeKeyAndOrderFront(nil)
        focusActivePaneSurface(inWindow: windows[idx])
    }

    func selectNextTab() { cycleTab(+1) }
    func selectPreviousTab() { cycleTab(-1) }

    /// Move selection by `delta` with wraparound.
    private func cycleTab(_ delta: Int) {
        guard let group = activeTabGroup(), !group.windows.isEmpty,
              let current = group.selectedWindow,
              let i = group.windows.firstIndex(of: current) else { return }
        let n = group.windows.count
        let j = ((i + delta) % n + n) % n
        group.selectedWindow = group.windows[j]
        group.windows[j].makeKeyAndOrderFront(nil)
        focusActivePaneSurface(inWindow: group.windows[j])
    }

    // MARK: - Live session linking

    /// Start polling once there's at least one tab *or* a parked agent; stop
    /// when both are empty. Detached agents need the FSEvents watcher + reconcile
    /// running so their cells stay lit even with no tabs open.
    private func updateLinkPolling() {
        if controllers.isEmpty && detachedAgents.isEmpty {
            linkTimer?.invalidate()
            linkTimer = nil
            awaitWatcher?.stop()
            awaitWatcher = nil
            if !liveConversationIDs.isEmpty { liveConversationIDs = [] }
            if !awaitingTurnIDs.isEmpty { awaitingTurnIDs = [] }
        } else if linkTimer == nil {
            Task { await reconcileLiveSessions() }
            // 8s matches the Context/Port poll cadence — finer than the live
            // badge needs, and lsof-per-tab is one of the heavier polls, so
            // this is pure standing-cost reduction.
            linkTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    // Skip the lsof reconcile while backgrounded — nothing on
                    // screen needs it; didBecomeActive runs one on return.
                    guard NSApp.isActive else { return }
                    await self?.reconcileLiveSessions()
                }
            }
            startAwaitWatcher()
        }
    }

    /// Watch the agent session roots so a turn-ending write flips the "your
    /// turn" light within the debounce window — no polling. FSEvents coalesces
    /// a turn's burst of writes into one callback; we then re-read only the
    /// live agent tabs' tails (cheap). Idle sessions trigger nothing.
    private func startAwaitWatcher() {
        guard awaitWatcher == nil else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let paths = [
            home.appendingPathComponent(".claude/projects", isDirectory: true).path,
            home.appendingPathComponent(".codex/sessions", isDirectory: true).path,
        ].filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        let watcher = FilesystemWatcher(paths: paths) { [weak self] in
            // FSEvents fires on a background queue; hop to main for @Published state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateAwaiting(live: self.liveConversationIDs)
                self.refreshDetachedStates()   // a background agent's turn lights its rail cell
            }
        }
        watcher.start()
        awaitWatcher = watcher
    }

    /// Detect which agent session (if any) each tab is running and adopt it as
    /// the tab's identity, so a hand-launched `claude`/`codex` stops being an
    /// orphan: the tab's badge/title flip to the agent, the sidebar marks it
    /// live, and clicking that conversation focuses this tab instead of
    /// spawning a duplicate `--resume`.
    private func reconcileLiveSessions() async {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        // Foreground pid → pane for every pane whose surface is up.
        let pidToPane = foregroundPIDs()
        let pids = Array(pidToPane.keys)

        let info = await Task.detached(priority: .utility) {
            LiveSessionLinker.inspect(pids: pids)
        }.value

        // Re-validate after the await: a pane may have closed or its foreground
        // process changed during the lsof. Iterate the CURRENT foreground map
        // (not the pre-await snapshot) so we never apply to a closed pane or a
        // reused pid.
        var live: Set<String> = []
        var adopted: Set<String> = []   // conversations already claimed this pass
        for (pid, pane) in foregroundPIDs() {
            // Only trust `info` for a pid that still maps to the SAME pane.
            guard pidToPane[pid] === pane else { continue }
            if pane.base.agent == .shell {
                // A bare shell pane: adopt the agent it hand-launched (or revert
                // to shell when none runs). If another pane in the same room
                // already claimed this conversation this pass, keep this one a
                // shell — two panes must not share one identity.
                var detected = detectConversation(for: info[pid])
                if let d = detected, adopted.contains(d.id) { detected = nil }
                pane.applyDetectedSession(detected)
                if let detected { adopted.insert(detected.id); live.insert(detected.id) }
            } else {
                // Opened as a concrete agent (resume): identity is FIXED. Live
                // while an agent process runs in it.
                if agentRunning(info[pid]) { live.insert(pane.base.id) }
            }
        }
        if liveConversationIDs != live { liveConversationIDs = live }
        // Keep each window's title on its active pane (adoption may have flipped it).
        for c in controllers { c.window?.title = c.holder.conversation.roomName }

        // With the live set settled, refresh the "your turn" lights from each
        // live agent tab's session file, and the parked agents' rail cells.
        updateAwaiting(live: live)
        refreshDetachedStates()

        // A tab may have just adopted a hand-launched agent (its effective
        // conversation changed without controllers changing) — re-persist so the
        // restore snapshot reflects the agent, not the bare shell it started as.
        schedulePersist()
    }

    /// Whether a tab's foreground process looks like a running agent — used for
    /// the live indicator on fixed-identity (resumed) tabs without resolving
    /// *which* conversation (that's already pinned to the tab's base).
    private func agentRunning(_ info: LiveSessionLinker.ProcessInfo?) -> Bool {
        guard let info else { return false }
        if info.openSessionFile != nil { return true }
        let c = info.command.lowercased()
        // A resumed agent now runs under a `dtach` master (see TerminalCommand /
        // Dtach), so the surface's foreground process is `dtach`, not the agent.
        // For these fixed-identity panes that's the live signal — the master
        // wraps the agent (or its drop-to-shell fallback) for this whole pane.
        return c.hasPrefix("claude") || c.hasPrefix("codex") || c.hasPrefix("dtach")
    }

    /// Every live pane across every window, keyed by foreground pid.
    private func foregroundPIDs() -> [Int32: Pane] {
        var out: [Int32: Pane] = [:]
        for c in controllers {
            for pane in c.workspace.panes {
                guard let surface = pane.surfaceView?.surface else { continue }
                let pid = ghostty_surface_foreground_pid(surface)
                if pid > 0 { out[Int32(pid)] = pane }
            }
        }
        return out
    }

    /// All panes across all windows (liveness, attention, persistence).
    private func allPanes() -> [Pane] { controllers.flatMap { $0.workspace.panes } }

    /// Synchronous live detection (used by `snapshot()`): controller → the
    /// agent conversation it's running, if any. Cheap `lsof` of a handful of
    /// pids — fine on the save-group click.
    private func detectLiveConversations() -> [ObjectIdentifier: Conversation] {
        // Snapshot is per-window (active pane) for now; full multi-pane capture
        // lands with PersistedWorkspace (Phase 7). Build a controller→pid map
        // from each window's active pane.
        var pidToController: [Int32: TerminalTabWindowController] = [:]
        for c in controllers {
            guard let surface = c.holder.surfaceView?.surface else { continue }
            let pid = ghostty_surface_foreground_pid(surface)
            if pid > 0 { pidToController[Int32(pid)] = c }
        }
        guard !pidToController.isEmpty else { return [:] }
        let info = LiveSessionLinker.inspect(pids: Array(pidToController.keys))
        var out: [ObjectIdentifier: Conversation] = [:]
        for (pid, controller) in pidToController {
            guard controller.base.agent == .shell else { continue }
            if let detected = detectConversation(for: info[pid]) {
                out[ObjectIdentifier(controller)] = detected
            }
        }
        return out
    }

    /// Resolve a tab's foreground process to a conversation: the open session
    /// file (Codex) wins; otherwise, a running `claude` is linked to the
    /// most-recently-active conversation in its cwd (Claude doesn't hold the
    /// file open, so cwd + recency is the best precise-enough signal).
    private func detectConversation(for info: LiveSessionLinker.ProcessInfo?) -> Conversation? {
        guard let info else { return nil }
        if let path = info.openSessionFile, info.command.lowercased().hasPrefix("codex"),
           let match = registry.conversations.first(where: { $0.sessionFile.path == path }) {
            return match
        }
        guard info.command.lowercased().hasPrefix("claude"), let cwd = info.cwd else { return nil }
        return registry.conversations
            .filter { $0.agent == .claudeCode && $0.roomPath.path == cwd }
            .max { $0.lastActivityAt < $1.lastActivityAt }
    }
}

