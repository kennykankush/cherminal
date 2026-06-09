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
            rebuildTabOverviews()   // keep the quick-look minimap's tab list current
            schedulePersist()       // keep the restore snapshot current on every open/close
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
    /// moment you focus the tab. The Dock badge mirrors the count (agents waiting
    /// on you that you haven't looked at).
    @Published private(set) var awaitingTurnIDs: Set<String> = [] {
        didSet { FleetAlerts.updateBadge(awaitingTurnIDs.count) }
    }

    /// Open panes whose agent is waiting on you *right now* — a live status set
    /// for the quick-look minimap, recomputed fresh each pass. Unlike
    /// `awaitingTurnIDs` (an unread badge: cleared once you view a pane, only
    /// re-lit by a turn newer than you've seen), this has NO view-suppression and
    /// NO seen-size gating: it reflects the raw "agent finished its turn" state of
    /// every open agent pane, including the one you're focused on. That's what the
    /// minimap wants — a glanceable picture of which panes are done, not which
    /// have unread output. Clears when you send input (the agent writes a user
    /// record → no longer awaiting).
    @Published private(set) var awaitingPaneIDs: Set<String> = []

    /// Agent types that have hit their account usage/plan limit ("burst"). Detected
    /// from any one pane's visible terminal banner (BurstDetector) and applied to
    /// the WHOLE agent type — the limit is account-wide, so all its panes go red.
    @Published private(set) var burstingAgents: Set<AgentKind> = []

    /// Per-conversation byte offset of the turn you've already seen (the session
    /// file's size when you last focused its tab). A completed turn only lights
    /// up when the file has grown past this — so re-focusing a tab you've
    /// already read doesn't re-trigger, and only a genuinely *new* turn does.
    private var seenTurnSize: [String: UInt64] = [:]

    /// Conversation id → the session file the live agent is ACTUALLY writing,
    /// discovered from `lsof` (the open file) each reconcile. Codex `resume` forks
    /// a brand-new rollout file instead of appending to the registry's one, so its
    /// tracked `sessionFile` goes stale — turn detection (done/working) must read
    /// this live file instead. Empty for claude (it doesn't hold the file open;
    /// its `--resume` appends to the same file, so `sessionFile` stays correct).
    private var liveSessionFile: [String: URL] = [:]

    /// Agents detached into the side rail: their pane was closed but their
    /// `dtach` master is still alive, so they keep running off-screen for ≈0
    /// memory. The tray UI renders one cell per entry, lit by `state`.
    @Published private(set) var detachedAgents: [DetachedAgent] = [] {
        didSet {
            updateLinkPolling()   // keep the watcher/poll alive while the tray has agents
            persistDetached()     // survive relaunch (reconciled against live masters)
        }
    }

    /// One open tab, surfaced to the quick-look minimap (Sessions inspector tab).
    /// `workspace` is the live ObservableObject — the minimap observes it directly
    /// for pane/layout/activePaneID changes, so this list only needs rebuilding
    /// when a tab opens or closes (see `controllers.didSet`). Order = tab order.
    struct TabOverview: Identifiable {
        let id: ObjectIdentifier      // the owning controller's identity
        let title: String
        let workspace: Workspace
    }

    /// Published snapshot of the open tabs, for the quick-look minimap.
    @Published private(set) var tabOverviews: [TabOverview] = []

    /// The frontmost tab — drives the "you are here" mark in the minimap. Updated
    /// as windows become key; nil until the first tab takes key.
    @Published private(set) var frontmostTabID: ObjectIdentifier?

    /// Set the instant the app starts quitting. Closing a window during normal
    /// use detaches its agents to the tray; closing windows during *termination*
    /// must not — the masters survive anyway and session restore reattaches them
    /// into tabs on next launch, so tray-on-quit would just duplicate them.
    private var isTerminating = false
    func beginTermination() { isTerminating = true }

    /// Set while `applicationShouldTerminate` is deciding (the reopen prompt may
    /// be up). Suppresses close-time parking so a just-closed last window's panes
    /// aren't parked mid-decision — the quit flow owns them (restore on
    /// cancel/reopen, reap on Don't-Reopen). Cleared on Cancel; superseded by
    /// `isTerminating` on a real quit.
    var terminationDecisionPending = false

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
        let oid = ObjectIdentifier(controller)
        if frontmostTabID != oid { frontmostTabID = oid }   // "you are here" in the minimap
        let id = controller.conversation.id
        awaitingTurnIDs.remove(id)
        FleetAlerts.clearDelivered(conversationID: id)   // you looked — drop the banner
        seenTurnSize[id] = Self.fileSize(controller.conversation.sessionFile)
    }

    /// Recompute which live agent tabs are awaiting you, from their session
    /// files. Called at the tail of each live-session reconcile (same 8s
    /// cadence), so the light follows turn completion without any bell.
    private func updateAwaiting(live: Set<String>) {
        var awaiting = awaitingTurnIDs
        var panesAwaiting: Set<String> = []   // minimap: raw "waiting now", rebuilt each pass
        for controller in controllers {
            let isKey = controller.window?.isKeyWindow == true
            for pane in controller.workspace.panes {
                let convo = pane.conversation
                let id = convo.id
                guard live.contains(id), convo.agent == .claudeCode || convo.agent == .codex else { continue }
                // Codex writes to a forked rollout file on resume; read the live
                // one lsof found, falling back to the tracked file (claude's stays
                // correct, so this is a no-op there).
                let file = liveSessionFile[id] ?? convo.sessionFile
                let reading = TurnState.read(sessionFile: file, agent: convo.agent)
                // Minimap signal: lit whenever the agent is awaiting you, no
                // matter which pane you're looking at (a live status, not a badge).
                if reading.awaitingUser { panesAwaiting.insert(id) }
                // Sidebar "your turn" badge (unread semantics): "viewed" = its
                // window is key AND it's the active pane.
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
        if awaitingTurnIDs != awaiting {
            // Notify for each agent that JUST entered "your turn" (a new completed
            // turn in a pane you're not viewing) — before we overwrite the set.
            let newlyDone = awaiting.subtracting(awaitingTurnIDs)
            awaitingTurnIDs = awaiting   // didSet refreshes the Dock badge
            for id in newlyDone {
                if let convo = conversation(forAwaitingID: id) { FleetAlerts.notifyDone(convo) }
            }
        }
        if awaitingPaneIDs != panesAwaiting { awaitingPaneIDs = panesAwaiting }
    }

    /// The live conversation behind an awaiting id (for the finish notification).
    private func conversation(forAwaitingID id: String) -> Conversation? {
        for c in controllers {
            for pane in c.workspace.panes where pane.conversation.id == id {
                return pane.conversation
            }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Open / focus

    /// Find an open pane running `id`, PREFERRING a pane opened *as* that
    /// conversation (`base.id` — the identity you actually chose) over one that
    /// merely *adopted* it (`conversation.id` — a best-effort guess for a
    /// hand-launched Claude, which can be wrong when a room has several Claude
    /// conversations). Two full passes across all windows so the exact match
    /// always wins over an adopted guess, regardless of tab order. This is what
    /// makes "click conversation X" land on X and not a pane that guessed X.
    private func findOpenPane(forConversationID id: String) -> (TerminalTabWindowController, Pane)? {
        for controller in controllers {
            if let pane = controller.workspace.panes.first(where: { $0.base.id == id }) {
                return (controller, pane)
            }
        }
        for controller in controllers {
            if let pane = controller.workspace.panes.first(where: { $0.conversation.id == id }) {
                return (controller, pane)
            }
        }
        return nil
    }

    /// Open `conversation` in a new native tab, or select its existing tab.
    @discardableResult
    func openOrFocus(_ conversation: Conversation, forceNew: Bool = false) -> TerminalTabWindowController? {
        clog("tabs", "openOrFocus id=\(conversation.id) agent=\(conversation.agent.rawValue) room=\(conversation.roomName) path=\(conversation.roomPath.path)")
        // Focus an existing tab/pane already running this conversation — searching
        // ALL panes (preferring opened identity over adopted, see findOpenPane),
        // not just each tab's active pane, so a restored grid holding it in a
        // non-active slot is found instead of spawning a duplicate dtach socket.
        if !forceNew, let (controller, pane) = findOpenPane(forConversationID: conversation.id) {
            clog("tabs", "→ focus existing pane")
            select(controller)
            focusPane(pane, in: controller.workspace)
            return controller
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
        // NOTE: we do NOT clear the tray cell here synchronously — at launch a
        // surface can spawn (restoreSession) BEFORE restoreDetachedAgents() loads
        // the saved tray, and detachedAgents' didSet persists, so mutating the
        // (still-empty) in-memory tray would clobber the saved parked sessions.
        // The async block below clears it (guarded so an empty tray never
        // persists), and parking is suppressed during a quit decision anyway.
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
                // reattaches the same master. Guard the mutation so a no-op never
                // fires detachedAgents' persist didSet — at launch this can run
                // before restoreDetachedAgents() loads the saved tray, and an empty
                // persist would clobber the saved parked sessions.
                if self.detachedAgents.contains(where: { $0.id == conversation.id }) {
                    self.detachedAgents.removeAll { $0.id == conversation.id }
                }
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
        guard let (controller, pane) = findOpenPane(forConversationID: conversationID) else { return false }
        select(controller)
        focusPane(pane, in: controller.workspace)
        return true
    }

    private func addPane(_ conversation: Conversation, to controller: TerminalTabWindowController, role: PaneRole? = nil) {
        guard controller.workspace.panes.count < 16 else { return }
        let pane = Pane(conversation: conversation, role: role)
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

    /// Activate a pane programmatically (⌘`, spawn, tab select, rail reattach).
    /// Sets the active-pane border AND moves the AppKit first responder to the
    /// pane's surface — these must stay in lockstep. Plain mouse clicks don't come
    /// through here: the surface takes first responder on click (via the window's
    /// local mouse-down monitor, and its own mouseDown as a fallback — both
    /// pixel-accurate), and the active pane follows via
    /// .chmSurfaceDidBecomeFirstResponder → syncActivePane. For that hit-test to
    /// reach the surface, the cell's SwiftUI overlays are non-interactive and the
    /// per-cell focus gesture is disabled on live panes (see TerminalGridView).
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

    /// Rebuild the quick-look minimap's tab snapshot from the live controllers.
    /// Cheap; runs on every tab open/close. Per-tab pane/layout/active changes are
    /// observed directly off each Workspace, so they don't trigger a rebuild.
    private func rebuildTabOverviews() {
        tabOverviews = controllers.map {
            TabOverview(id: ObjectIdentifier($0), title: $0.conversation.roomName, workspace: $0.workspace)
        }
    }

    /// Jump to the pane running `id` (a finish-notification tap). Selects its tab
    /// and focuses it; no-op if that conversation isn't open in a pane anymore.
    func revealConversation(id: String) {
        focusExistingPane(conversationID: id)
    }

    /// The file the live agent is actually writing for `id`, when it differs from
    /// the tracked one (codex forks a new rollout on resume). nil → use the
    /// conversation's own sessionFile. Lets the inspector's usage readout follow
    /// codex's live rollout instead of a frozen file.
    func liveFile(for id: String) -> URL? { liveSessionFile[id] }

    /// Cycle focus to the next agent pane waiting on you (the cells lit in the
    /// minimap), across all tabs and panes, wrapping. No-op when none are waiting.
    /// Lets you clear a fleet of finished agents with one repeated keystroke.
    func focusNextWaiting() {
        var waiting: [(controller: TerminalTabWindowController, pane: Pane)] = []
        for c in controllers {
            for pane in c.workspace.panes where awaitingPaneIDs.contains(pane.conversation.id) {
                waiting.append((c, pane))
            }
        }
        guard !waiting.isEmpty else { return }
        // Resume after the currently-focused pane, so repeated presses advance.
        let key = NSApp.keyWindow
        let cur = waiting.firstIndex {
            $0.controller.window === key && $0.controller.workspace.activePaneID == $0.pane.id
        }
        let next = waiting[((cur ?? -1) + 1) % waiting.count]
        select(next.controller)
        focusPane(next.pane, in: next.controller.workspace)
    }

    /// Jump to a pane from the quick-look minimap: select its tab window and move
    /// keyboard focus to the pane.
    func reveal(_ pane: Pane) {
        guard let controller = controllers.first(where: { c in
            c.workspace.panes.contains { $0.id == pane.id }
        }) else { return }
        select(controller)
        focusPane(pane, in: controller.workspace)
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
    /// Park a closed pane in the tray (master kept alive for one-click reattach).
    /// Agents always park; a plain shell parks only when it's dtach-wrapped
    /// (persistent sessions on) — an unwrapped shell has no surviving master, so
    /// there's nothing to park (it just died on surface teardown, as today).
    /// Parking is reversible and race-free: reattach (or restore, on a canceled
    /// quit) removes the tray cell and reattaches the same live master — which is
    /// why we park rather than reap on close.
    private func detachToTray(_ convo: Conversation) {
        // Don't park while a quit decision is pending (the close-last-window
        // reopen prompt is up) or during termination — the quit flow owns these
        // panes (restore on cancel/reopen, reap on Don't-Reopen). Parking here
        // would race that decision and could spare a pane from the Don't-Reopen reap.
        guard !isTerminating, !terminationDecisionPending else { return }
        let isAgent = convo.agent == .claudeCode || convo.agent == .codex
        // Park only if there's a live dtach master to keep. Agents always have
        // one; a shell does only if it was dtach-wrapped at spawn — decided by
        // ACTUAL socket liveness, not the current preference (the user may have
        // toggled persistentSessions off after the pane spawned).
        guard isAgent || Dtach.isMasterAlive(id: convo.id) else { return }
        // Don't park a pane that's currently open — e.g. restored after a canceled
        // quit before this deferred park ran. It would duplicate the live session
        // as a tray cell while the open pane owns the master.
        guard !controllers.contains(where: { c in
            c.workspace.panes.contains { $0.base.id == convo.id || $0.conversation.id == convo.id }
        }) else { return }
        guard !detachedAgents.contains(where: { $0.id == convo.id }) else { return }
        detachedAgents.append(DetachedAgent(conversation: convo))
        clog("tabs", "detached \(convo.agent.rawValue) \(convo.id) → tray")
        refreshDetachedStates()
        enforceShellTrayLimits()
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
    /// JSONL tail read every time, master liveness (one shared ProcTable
    /// snapshot, previously an lsof per agent) at most every ~4s — then publish
    /// any changes. Driven by the FSEvents callback + 8s reconcile.
    private func refreshDetachedStates() {
        guard !detachedAgents.isEmpty, !detachedRefreshing else { return }
        detachedRefreshing = true
        let agents = detachedAgents
        let wantLiveness = Date().timeIntervalSince(lastLivenessCheck) > 4
        Task.detached(priority: .utility) {
            // A failed snapshot means "liveness unknown", never "dead" — a
            // wedged lsof must not flip every parked agent's cell to dead.
            let table = wantLiveness ? ProcTable.cached(socketDir: Dtach.directory) : nil
            let checkedLiveness = table != nil
            var next: [String: DetachState] = [:]
            for a in agents {
                if let table, !Dtach.isMasterAlive(id: a.id, table: table) {
                    next[a.id] = .dead; continue
                }
                // A parked shell has no agent session file to read — its state is
                // purely master liveness (alive → working).
                guard a.conversation.agent == .claudeCode || a.conversation.agent == .codex else {
                    next[a.id] = .working; continue
                }
                let reading = TurnState.read(sessionFile: a.conversation.sessionFile, agent: a.conversation.agent)
                next[a.id] = reading.awaitingUser ? .attention : .working
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.detachedRefreshing = false
                if checkedLiveness { self.lastLivenessCheck = Date() }
                let updated = self.detachedAgents.map { agent -> DetachedAgent in
                    guard let s = next[agent.id] else { return agent }
                    // Don't resurrect a known-dead cell from a stale file read on
                    // a tick where liveness wasn't (successfully) checked.
                    let resolved: DetachState = (!checkedLiveness && agent.state == .dead) ? .dead : s
                    guard resolved != agent.state else { return agent }
                    var copy = agent; copy.state = resolved; return copy
                }
                if updated != self.detachedAgents { self.detachedAgents = updated }
            }
        }
    }

    // MARK: - Tray lifecycle (anti-leak: bound parked SHELL sessions)

    /// Max parked SHELL masters kept alive before the oldest are reaped. Agents
    /// are never auto-reaped (the user manages those via the tray's Kill).
    private static let maxParkedShells = 16
    /// A parked shell left un-reattached longer than this is treated as forgotten
    /// and reaped — its dtach master would otherwise run indefinitely.
    private static let parkedShellMaxAge: TimeInterval = 24 * 60 * 60   // 24h

    /// Honor the "no dtach forever" rule for SHELLS: reap parked shell masters
    /// that are stale (parked > maxAge) or beyond the cap (oldest first). Parked
    /// AGENTS are left untouched. Naturally inert when persistent sessions are off
    /// (no shell has a master to park). Reattaching a shell removes its cell and
    /// resets its age, so this only ever hits genuinely-forgotten shells.
    private func enforceShellTrayLimits() {
        let now = Date()
        let shells = detachedAgents.filter { $0.conversation.agent == .shell }
        guard !shells.isEmpty else { return }
        var reap = Set<String>()
        // Age: shells parked longer than the max age are forgotten.
        for s in shells where now.timeIntervalSince(s.detachedAt) > Self.parkedShellMaxAge {
            reap.insert(s.id)
        }
        // Cap: among the rest, keep the most-recently parked and reap the oldest
        // beyond the cap.
        let fresh = shells.filter { !reap.contains($0.id) }.sorted { $0.detachedAt > $1.detachedAt }
        if fresh.count > Self.maxParkedShells {
            for s in fresh[Self.maxParkedShells...] { reap.insert(s.id) }
        }
        guard !reap.isEmpty else { return }
        for id in reap { Dtach.kill(id: id) }
        detachedAgents.removeAll { reap.contains($0.id) }
        clog("tabs", "tray: reaped \(reap.count) stale/over-cap shell session(s)")
    }

    // MARK: - Ports

    /// Cheap per-pane refs (NO subprocess, main-actor safe) for the port watcher
    /// to resolve OFF the main actor: the dtach socket key (base.id), the
    /// conversation id, and the surface's foreground pid. PortsManager resolves a
    /// wrapped pane's master pid — where a dev server descends from, vs the surface
    /// client relay — off-main inside its scan task (see PortsManager.scan).
    func paneSocketRefs() -> [(socketID: String, conversationID: String, fgPID: Int32)] {
        var out: [(socketID: String, conversationID: String, fgPID: Int32)] = []
        for c in controllers {
            for pane in c.workspace.panes {
                guard let surface = pane.surfaceView?.surface else { continue }
                out.append((socketID: pane.base.id,
                            conversationID: pane.conversation.id,
                            fgPID: Int32(ghostty_surface_foreground_pid(surface))))
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
    private static let lastWorkspacesKey = "cherminal.lastWorkspaces"   // V2: full per-tab grid

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

    // MARK: - Persisted workspaces (full per-tab grid — supersedes single-pane PersistedTab)

    /// Snapshot every open tab's full grid (all panes + layout) so restore
    /// rebuilds the exact arrangement, not just the active pane. Uses each pane's
    /// *effective* conversation (already adopted by the live-session reconcile),
    /// so a hand-launched agent is saved as that agent.
    func currentWorkspaces(detected: [ObjectIdentifier: Conversation] = [:]) -> [PersistedWorkspace] {
        // A conversation may be serialized into ONE pane only — two panes can't
        // resume the same agent (they'd share a dtach socket), and restore's
        // dedup would otherwise silently drop a pane. Resolve each pane's
        // identity in two passes so a duplicate yields a *unique* fallback.
        let allPanes = controllers.flatMap { $0.workspace.panes }
        var identity: [ObjectIdentifier: Conversation] = [:]
        var claimed = Set<String>()

        // Pass 1: fixed-identity (agent) panes own their conversation id — they
        // were deliberately opened as that agent, so they win any collision with
        // a shell that merely hand-launched the same agent.
        for pane in allPanes where pane.base.agent != .shell {
            if claimed.insert(pane.conversation.id).inserted {
                identity[ObjectIdentifier(pane)] = pane.conversation
            } else {
                // Two fixed panes for one agent shouldn't occur (open/restore
                // dedup), but be safe: demote the duplicate to a fresh shell.
                let shell = Conversation.shellConversation(cwd: pane.conversation.roomPath)
                identity[ObjectIdentifier(pane)] = shell
                claimed.insert(shell.id)
            }
        }
        // Pass 2: shell panes — a freshly hand-launched agent (quit detection) or
        // the pane's adopted conversation, unless that id is already claimed, in
        // which case fall back to the pane's unique base shell identity.
        for pane in allPanes where pane.base.agent == .shell {
            var convo = detected[ObjectIdentifier(pane)] ?? pane.conversation
            if !claimed.insert(convo.id).inserted {
                convo = pane.base
                claimed.insert(convo.id)
            }
            identity[ObjectIdentifier(pane)] = convo
        }

        return controllers.map { controller in
            PersistedWorkspace(
                layout: controller.workspace.layout,
                panes: controller.workspace.panes.map { pane in
                    let convo = identity[ObjectIdentifier(pane)] ?? pane.conversation
                    return PersistedPane(
                        conversationID: convo.id,
                        agentRaw: convo.agent.rawValue,
                        roomPath: convo.roomPath.path,
                        role: pane.role,
                        gridPosition: pane.gridPosition,
                        socketID: convo.id)
                })
        }
    }

    /// Synchronous per-pane live detection for the quit snapshot: a shell pane
    /// that just hand-launched `claude`/`codex` is captured as that agent even if
    /// the periodic reconcile hasn't adopted it yet (preserves the pre-grid
    /// snapshot() guarantee). One ProcTable capture + one batched lsof, every
    /// probe watchdog-bounded — a wedged lsof can no longer hang the quit.
    private func detectLivePaneConversations() -> [ObjectIdentifier: Conversation] {
        let table = ProcTable.cached(socketDir: Dtach.directory)
        let pidToPane = foregroundPIDs(table: table)
        guard !pidToPane.isEmpty else { return [:] }
        let info = LiveSessionLinker.inspect(pids: Array(pidToPane.keys),
                                             argvByPID: table?.argv)
        var out: [ObjectIdentifier: Conversation] = [:]
        var adopted = Set<String>()   // mirror reconcileLiveSessions: one pane per convo
        for (pid, pane) in pidToPane where pane.base.agent == .shell {
            guard let detected = detectConversation(for: info[pid]),
                  adopted.insert(detected.id).inserted else { continue }
            out[ObjectIdentifier(pane)] = detected
        }
        return out
    }

    /// Resolve a persisted pane to a live conversation: a shell reopens in its
    /// room (reusing its id so it maps to the same pane); an agent resumes if its
    /// session still exists, else falls back to a shell there. Mirrors
    /// openPersistedTabs' rules.
    private func conversation(forPersistedPane pane: PersistedPane) -> Conversation {
        if pane.agentRaw == AgentKind.shell.rawValue {
            return Conversation.shellConversation(
                cwd: URL(fileURLWithPath: pane.roomPath), id: pane.conversationID)
        }
        if let real = registry.conversation(id: pane.conversationID) { return real }
        // Registry miss (session not in the cache yet — brand-new, or scanned
        // after the snapshot loaded). DON'T downgrade to a blank shell: that
        // loses the conversation and strands its still-running dtach master.
        // Resume the agent by its persisted id instead; the registry fills in the
        // accurate details after bootstrap. Keeping the id also lets the tray
        // restore correctly skip it (it's now genuinely open as this agent).
        let agent = AgentKind(rawValue: pane.agentRaw) ?? .unknown
        return Conversation.restoredAgent(
            id: pane.conversationID, agent: agent, room: URL(fileURLWithPath: pane.roomPath))
    }

    /// Open saved full-grid workspaces: one tab per workspace, its first pane
    /// opening the tab and the rest filling the grid in order.
    func openPersistedWorkspaces(_ workspaces: [PersistedWorkspace]) {
        var seen = Set<String>()   // conversation ids already restored
        for workspace in workspaces {
            // Drop any pane whose conversation id already appeared: two panes must
            // never resume the same agent (they'd share one dtach socket and
            // mirror I/O). Shell ids are unique per pane, so only genuine dups get
            // dropped. forceNew gives each workspace its OWN tab — openOrFocus's
            // dedup would otherwise merge two workspaces sharing a first-pane id.
            let panes = workspace.panes.filter { seen.insert($0.conversationID).inserted }
            guard let first = panes.first,
                  let controller = openOrFocus(conversation(forPersistedPane: first), forceNew: true)
            else { continue }
            for pane in panes.dropFirst() {
                addPane(conversation(forPersistedPane: pane), to: controller, role: pane.role)
            }
        }
    }

    /// The workspaces persisted by the last run (V2), migrating the older
    /// single-pane [PersistedTab] blob (V1) when no V2 snapshot exists yet.
    func savedWorkspaces() -> [PersistedWorkspace] {
        if let data = UserDefaults.standard.data(forKey: Self.lastWorkspacesKey),
           let workspaces = try? JSONDecoder().decode([PersistedWorkspace].self, from: data) {
            return workspaces
        }
        return savedSessionTabs().map { tab in
            PersistedWorkspace(layout: .single, panes: [
                PersistedPane(conversationID: tab.conversationID,
                              agentRaw: tab.agentRaw,
                              roomPath: tab.roomPath,
                              role: nil,
                              gridPosition: GridPosition(row: 0, col: 0),
                              socketID: tab.conversationID)
            ])
        }
    }

    /// Snapshot the open tabs to disk so the next launch can reopen them (V2
    /// full grid). Uses each pane's *effective* conversation (the live-session
    /// reconcile already adopts a hand-launched agent into the pane), so we
    /// capture the right identity without a fresh lsof. Called on quit.
    func persistSession() {
        // Never clobber the continuous save with an empty set: an empty result at
        // terminate is almost always teardown — macOS closes the windows
        // (emptying controllers) before this runs — so skipping protects a good
        // snapshot from that race. The debounced persistSessionLight already
        // writes the real set the moment you genuinely close everything.
        let workspaces = currentWorkspaces(detected: detectLivePaneConversations())
        guard !workspaces.isEmpty else {
            clog("tabs", "terminate snapshot empty — keeping the continuous save")
            return
        }
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastWorkspacesKey)
        clog("tabs", "persisted \(workspaces.count) workspace(s) for next launch")
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
        // V2: persist every tab's full grid. Do NOT clobber the saved set with []
        // just because every tab closed — closing the last tab (→ placeholder)
        // used to wipe the session so a later quit restored nothing. We keep the
        // last non-empty snapshot; only "Don't Reopen" clears it (see
        // clearSavedSession / reopenChoice).
        persistWorkspaces()
    }

    /// Encode the current full-grid workspaces to disk (V2). Shared by the
    /// debounced continuous save and the quit snapshot. Empty-guarded so a
    /// teardown race can't wipe a good snapshot.
    private func persistWorkspaces() {
        let workspaces = currentWorkspaces()
        guard !workspaces.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastWorkspacesKey)
    }

    /// Forget the saved session so the next launch starts fresh. Called when the
    /// user answers "Don't Reopen" at quit.
    func clearSavedSession() {
        UserDefaults.standard.removeObject(forKey: Self.lastSessionKey)
        UserDefaults.standard.removeObject(forKey: Self.lastWorkspacesKey)
        // "Don't Reopen" abandons the whole session, so reap every dtach master
        // EXCEPT those the tray intentionally keeps alive (parked agents survive,
        // same as today). Sweeping by socket (not by open panes) covers both
        // still-attached panes AND a just-closed last window whose controller is
        // already gone by the time this runs on the close-last-window quit path.
        // At launch this is harmlessly redundant with the launch sweep that follows.
        let keep = Set(savedDetached().map { $0.conversationID })
        for id in Dtach.knownSocketIDs() where !keep.contains(id) {
            Dtach.kill(id: id)
        }
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
        let workspaces = savedWorkspaces()
        guard !workspaces.isEmpty else { return false }
        let paneCount = workspaces.reduce(0) { $0 + $1.panes.count }
        clog("tabs", "restoring \(workspaces.count) tab(s), \(paneCount) pane(s) from last session")
        openPersistedWorkspaces(workspaces)
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
                         roomPath: $0.conversation.roomPath.path,
                         detachedAt: $0.detachedAt)
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
        // One snapshot answers liveness for every saved agent (was an lsof
        // each). If the snapshot failed, fall back to per-socket probes —
        // restore must not silently drop parked agents on a wedged lsof.
        let table = ProcTable.cached(socketDir: Dtach.directory)
        func alive(_ id: String) -> Bool {
            if let table { return Dtach.isMasterAlive(id: id, table: table) }
            return Dtach.isMasterAlive(id: id)
        }
        var restored: [DetachedAgent] = []
        for it in saved {
            guard alive(it.conversationID) else { continue }
            // Skip ids already open as a pane (restoreSession ran first): one
            // master must not be both a tab and a tray cell.
            if controllers.contains(where: { c in
                c.workspace.panes.contains { $0.base.id == it.conversationID || $0.conversation.id == it.conversationID }
            }) { continue }
            let convo: Conversation
            if it.agentRaw == AgentKind.shell.rawValue {
                // Synthetic shell — reconstruct from the persisted room + id (no
                // registry entry exists for a shell).
                convo = Conversation.shellConversation(
                    cwd: URL(fileURLWithPath: it.roomPath), id: it.conversationID)
            } else if let real = registry.conversation(id: it.conversationID) {
                convo = real
            } else {
                continue
            }
            // Preserve the original park time so the shell age-reap survives
            // relaunch (a long-forgotten shell isn't treated as freshly parked).
            restored.append(DetachedAgent(conversation: convo, detachedAt: it.detachedAt ?? Date()))
        }
        // Always assign (even when empty) so the persisted tray reflects the
        // FILTERED set — dead masters and already-open (skipped) ids are dropped
        // from cherminal.detachedAgents. Otherwise a stale on-disk entry could
        // later let clearSavedSession's keep-set spare an open pane's master from
        // the Don't-Reopen reap. (Reads savedDetached() above first, so no self-clobber.)
        detachedAgents = restored
        refreshDetachedStates()
        enforceShellTrayLimits()
    }

    /// Reap dtach masters that nothing will reattach. At launch, the only
    /// sockets we keep are those a restored tab or a restored tray cell will
    /// reattach; any other live master is an orphan from a crash (it'd run
    /// forgotten), and any dead socket is stale — both get killed (socket
    /// removed). Run once, before restore, so nothing lingers invisibly.
    func sweepDtachSockets() {
        let savedPanes = savedWorkspaces().flatMap { $0.panes }
        let keep = Set(savedPanes.map { $0.conversationID })
            .union(savedPanes.compactMap { $0.socketID })
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
            if !awaitingPaneIDs.isEmpty { awaitingPaneIDs = [] }
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

        // Snapshot panes cheaply on the main actor (no subprocess): base.id is the
        // dtach socket key; the real inner pid is resolved off-main below.
        var paneByID: [String: Pane] = [:]
        var refs: [(socketID: String, fg: Int32, isShell: Bool)] = []
        for c in controllers {
            for pane in c.workspace.panes {
                guard let surface = pane.surfaceView?.surface else { continue }
                paneByID[pane.base.id] = pane
                refs.append((socketID: pane.base.id,
                             fg: Int32(ghostty_surface_foreground_pid(surface)),
                             isShell: pane.base.agent == .shell))
            }
        }

        // Off the main actor: resolve each pane's effective pid by seeing THROUGH
        // dtach to the inner foreground process (the running agent), for AGENTS as
        // well as shells — both are dtach-wrapped, and the surface's own foreground
        // pid is the `login`/dtach-client wrapper, which lsof can't inspect (login
        // is setuid root) so it never identifies the agent. One shared ProcTable
        // snapshot (2 bounded spawns, TTL-cached across reconcile/ports/tray)
        // answers every per-pane question — previously this loop spawned
        // lsof+pgrep+ps PER PANE every tick. Fall back to the surface pid only
        // for a genuinely unwrapped pane. ALL subprocess work happens here,
        // never on @MainActor.
        let probed = await Task.detached(priority: .utility) {
            () -> ([(socketID: String, pid: Int32)], [Int32: LiveSessionLinker.ProcessInfo])? in
            // Snapshot failed (lsof/ps wedged → watchdog killed it): skip this
            // tick and keep the previous live state — "unknown" must never be
            // read as "everything exited".
            guard let table = ProcTable.cached(socketDir: Dtach.directory) else { return nil }
            var resolved: [(socketID: String, pid: Int32)] = []
            for r in refs {
                if let inner = Dtach.innerForegroundPID(id: r.socketID, table: table) {
                    resolved.append((socketID: r.socketID, pid: Int32(inner)))
                } else if r.fg > 0 {
                    resolved.append((socketID: r.socketID, pid: r.fg))
                }
            }
            let info = LiveSessionLinker.inspect(pids: resolved.map { $0.pid },
                                                 argvByPID: table.argv)
            return (resolved, info)
        }.value
        guard let (resolved, info) = probed else { return }

        // Back on main: map each effective pid to its still-open pane, then adopt.
        // Keying by the stable socket id (base.id) sidesteps the pid-reuse hazard
        // the old re-snapshot guarded against; we just re-check the pane is open.
        var live: Set<String> = []
        var adopted: Set<String> = []   // conversations already claimed this pass
        var liveFiles: [String: URL] = [:]   // id → the file lsof says it's writing (codex)
        for (socketID, pid) in resolved {
            guard let pane = paneByID[socketID], pane.surfaceView != nil,
                  controllers.contains(where: { $0.workspace.panes.contains { $0 === pane } })
            else { continue }
            let openFile = info[pid]?.openSessionFile.map { URL(fileURLWithPath: $0) }
            if pane.base.agent == .shell {
                // A bare shell pane: adopt the agent it hand-launched (or revert
                // to shell when none runs). If another pane already claimed this
                // conversation this pass, keep this one a shell — two panes must
                // not share one identity.
                var detected = detectConversation(for: info[pid])
                if let d = detected, adopted.contains(d.id) { detected = nil }
                pane.applyDetectedSession(detected)
                if let detected {
                    adopted.insert(detected.id); live.insert(detected.id)
                    if let openFile { liveFiles[detected.id] = openFile }
                }
            } else {
                // Opened as a concrete agent (resume): identity is FIXED. Live
                // while an agent process runs in it.
                if agentRunning(info[pid]) {
                    live.insert(pane.base.id)
                    if let openFile { liveFiles[pane.base.id] = openFile }
                }
            }
        }
        if liveConversationIDs != live { liveConversationIDs = live }
        liveSessionFile = liveFiles   // codex's live rollout, for done/working detection

        // Burst scan: read each agent pane's visible terminal banner (cheap —
        // 500ms-cached viewport text) and flag the whole agent type if any pane
        // has hit its usage limit. Stops scanning an agent once it's flagged.
        var bursting: Set<AgentKind> = []
        for c in controllers {
            for pane in c.workspace.panes {
                let agent = pane.conversation.agent
                guard agent == .codex || agent == .claudeCode, !bursting.contains(agent),
                      let surface = pane.surfaceView else { continue }
                if BurstDetector.isBursting(agent: agent, visibleText: surface.cachedVisibleContents.get()) {
                    bursting.insert(agent)
                }
            }
        }
        if burstingAgents != bursting { burstingAgents = bursting }
        // Keep each window's title on its active pane (adoption may have flipped it).
        for c in controllers { c.window?.title = c.holder.conversation.roomName }

        // With the live set settled, refresh the "your turn" lights from each
        // live agent tab's session file, and the parked agents' rail cells.
        updateAwaiting(live: live)
        refreshDetachedStates()
        enforceShellTrayLimits()

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

    /// Every live pane across every window, keyed by foreground pid. Resolves
    /// wrapped shells through dtach via the supplied snapshot (no per-pane
    /// subprocess); when the snapshot is unavailable it falls back to the
    /// single-socket probe (bounded by the subprocess watchdog).
    private func foregroundPIDs(table: ProcTable?) -> [Int32: Pane] {
        var out: [Int32: Pane] = [:]
        for c in controllers {
            for pane in c.workspace.panes {
                guard let surface = pane.surfaceView?.surface else { continue }
                // A wrapped SHELL pane's surface foreground is the dtach client;
                // the hand-launched agent (if any) runs under the master, so look
                // through dtach to the inner foreground for adoption. Agent panes
                // keep the surface pid — their live signal already handles the
                // dtach client (agentRunning matches the "dtach" command).
                let inner: pid_t?
                if pane.base.agent == .shell {
                    inner = table.map { Dtach.innerForegroundPID(id: pane.base.id, table: $0) }
                        ?? Dtach.innerForegroundPID(id: pane.base.id)
                } else {
                    inner = nil
                }
                let pid: Int32
                if let inner {
                    pid = Int32(inner)
                } else {
                    let fg = ghostty_surface_foreground_pid(surface)
                    guard fg > 0 else { continue }
                    pid = Int32(fg)
                }
                out[pid] = pane
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
            let pane = c.holder
            guard let surface = pane.surfaceView?.surface else { continue }
            // Look through dtach for a wrapped shell (the hand-launched agent runs
            // under the master); else use the surface foreground pid.
            let pid: Int32
            if pane.base.agent == .shell, let inner = Dtach.innerForegroundPID(id: pane.base.id) {
                pid = Int32(inner)
            } else {
                let fg = ghostty_surface_foreground_pid(surface)
                guard fg > 0 else { continue }
                pid = Int32(fg)
            }
            pidToController[pid] = c
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
        // Most reliable: the exact session id from the process's OWN argv
        // (`claude --resume <id>` / `codex resume <id>`) — the conversation the
        // user actually selected. No guessing; works for both agents.
        if let id = info.resumeID, let match = registry.conversation(id: id) {
            return match
        }
        // Codex holds its rollout file open → exact open-file match.
        if let path = info.openSessionFile, info.command.lowercased().hasPrefix("codex"),
           let match = registry.conversations.first(where: { $0.sessionFile.path == path }) {
            return match
        }
        // Claude doesn't hold its file open and wasn't resumed by id (a fresh
        // session): best-effort — the most-recently-active Claude conversation in
        // the room. Inherently approximate when a room has several; the argv /
        // open-file paths above are the accurate ones.
        guard info.command.lowercased().hasPrefix("claude"), let cwd = info.cwd else { return nil }
        return registry.conversations
            .filter { $0.agent == .claudeCode && $0.roomPath.path == cwd }
            .max { $0.lastActivityAt < $1.lastActivityAt }
    }
}

