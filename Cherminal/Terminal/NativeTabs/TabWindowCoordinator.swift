import AppKit
import SwiftUI
import GhosttyKit
import os

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
        guard pane.surfaceView == nil else { return }
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
                clog("tabs", "spawn surface ok id=\(conversation.id) pane=\(pane.id)")
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
        guard controller.workspace.panes.count < controller.workspace.layout.capacity || controller.workspace.panes.count < 16 else { return }
        let cwd = controller.holder.conversation.roomPath
        let pane = Pane(conversation: Conversation.shellConversation(cwd: cwd))
        controller.workspace.addPane(pane)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        spawnSurface(for: pane, in: controller)
        schedulePersist()
    }

    /// Close the active pane; if it's the last one, close the window.
    func closeActivePane() {
        guard let controller = activeController else { return }
        let ws = controller.workspace
        guard ws.panes.count > 1, let active = ws.activePane else {
            controller.window?.performClose(nil)
            return
        }
        ws.removePane(id: active.id)   // pane deinit drops its surface (SIGHUP)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        schedulePersist()
    }

    func focusNextPane() { activeController?.workspace.focusNext() }

    /// Open a bare shell tab. cwd defaults to the active tab's room, else $HOME.
    func openFreshShell(cwd explicitCWD: URL? = nil) {
        let cwd = explicitCWD
            ?? activeConversation?.roomPath
            ?? URL(fileURLWithPath: NSHomeDirectory())
        openOrFocus(Conversation.shellConversation(cwd: cwd))
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
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastSessionKey)
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
        controllers.removeAll { $0 === controller }
        // The attention light is insert-on-bell / remove-on-focus; a tab that
        // closes while flagged would leak its id forever (clearAwaiting only
        // fires for still-registered windows). Clear both the effective and
        // base identity so a shell↔agent flip can't strand it either.
        awaitingTurnIDs.remove(controller.conversation.id)
        awaitingTurnIDs.remove(controller.base.id)

        // Last tab gone → show the "no tabs open" home window instead of letting
        // the app quit. Inherit the closing window's frame for continuity.
        // Deferred + re-checked: a new tab may open in the same beat (e.g. ⌘T).
        if controllers.isEmpty {
            let frame = controller.window?.frame
            DispatchQueue.main.async { [weak self] in
                guard let self, self.controllers.isEmpty else { return }
                self.showPlaceholder(near: frame)
            }
        }
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
    }

    // MARK: - Live session linking

    /// Start polling once there's at least one tab; stop when the last closes.
    private func updateLinkPolling() {
        if controllers.isEmpty {
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
                Task { @MainActor in await self?.reconcileLiveSessions() }
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
        // live agent tab's session file.
        updateAwaiting(live: live)

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
        return c.hasPrefix("claude") || c.hasPrefix("codex")
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
