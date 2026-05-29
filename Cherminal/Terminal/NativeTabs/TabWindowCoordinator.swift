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
        didSet { tabCount = controllers.count }
    }

    /// Published so bookmark UI can reflect how many tabs would be saved.
    @Published private(set) var tabCount: Int = 0 {
        didSet { updateLinkPolling() }
    }

    /// Conversation ids currently running live in a tab (hand-launched agents
    /// or resumed sessions). The sidebar reads this to show a live indicator.
    @Published private(set) var liveConversationIDs: Set<String> = []

    /// Conversations whose agent just finished a turn and is waiting on you —
    /// driven by Ghostty's bell (a command-finished proxy). The sidebar shows a
    /// calm blue "your turn" light for these; cleared when you focus the tab.
    @Published private(set) var awaitingTurnIDs: Set<String> = []

    /// Polls the live-session linker while any tab is open.
    private var linkTimer: Timer?
    /// Reentrancy guard: an `lsof` poll can outlast the 3s interval, so the
    /// next tick must not start a second overlapping reconcile (which would
    /// double-write tab identities / the live set).
    private var reconciling = false

    /// Notification observer tokens, removed in deinit (harmless today as a
    /// singleton, but correct if this ever stops being one).
    private var observers: [any NSObjectProtocol] = []

    init(registry: ConversationRegistry, ghostty: Ghostty.App, bookmarks: BookmarksManager) {
        self.registry = registry
        self.ghostty = ghostty
        self.bookmarks = bookmarks

        // "Your turn" attention light: flag a tab when its agent rings the bell
        // (turn finished), clear it the moment you focus that tab.
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyBellDidRing, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleBell(note.object) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.clearAwaiting(forWindow: note.object as? NSWindow) }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Attention light

    private func handleBell(_ object: Any?) {
        guard let surface = object as? Ghostty.SurfaceView,
              let controller = controllers.first(where: { $0.holder.surfaceView === surface })
        else { return }
        // Only agent tabs get the "your turn" light — the bell is a proxy for
        // turn-finished, and a plain shell ringing it isn't "your turn". (An
        // adopted shell reads as its agent here, so it still qualifies.)
        guard controller.conversation.agent != .shell else { return }
        // If you're already looking at this tab, there's nothing to flag.
        if controller.window?.isKeyWindow == true { return }
        awaitingTurnIDs.insert(controller.conversation.id)
    }

    private func clearAwaiting(forWindow window: NSWindow?) {
        guard let window,
              let controller = controllers.first(where: { $0.window === window }) else { return }
        awaitingTurnIDs.remove(controller.conversation.id)
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

        // Lay out the panes now, then spawn the surface on the next runloop —
        // once the sidebar + inspector have claimed their widths and the
        // terminal pane is at its real size. The shell (and its fastfetch
        // banner, which can't reflow) then start at the correct width instead
        // of into the momentarily-squished pane.
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        // Build the surface config OFF the main thread — TerminalCommand →
        // BinaryResolver can block up to 3s on a cold launch (sourcing ~/.zshrc),
        // which would freeze the UI. Hop back to the main actor only to
        // construct the SurfaceView (libghostty requires main), re-checking the
        // tab is still live (it may have closed during the off-main work).
        Task.detached(priority: .userInitiated) {
            let config = TerminalCommand.surfaceConfig(for: conversation)
            await MainActor.run { [weak self, weak controller] in
                guard let self,
                      let controller,
                      self.controllers.contains(where: { $0 === controller }),
                      controller.holder.surfaceView == nil,
                      let app = self.ghostty.app else { return }
                clog("tabs", "spawn surface id=\(conversation.id) cwd=\(config.workingDirectory ?? "nil") cmd=\(config.command ?? "default-shell")")
                controller.holder.surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
                clog("tabs", "spawn surface ok id=\(conversation.id)")
            }
        }
        return controller
    }

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
            guard let surface = c.holder.surfaceView?.surface else { continue }
            let pid = ghostty_surface_foreground_pid(surface)
            if pid > 0 { out[Int32(pid)] = c.conversation.id }
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
            if !liveConversationIDs.isEmpty { liveConversationIDs = [] }
        } else if linkTimer == nil {
            Task { await reconcileLiveSessions() }
            // 8s matches the Context/Port poll cadence — finer than the live
            // badge needs, and lsof-per-tab is one of the heavier polls, so
            // this is pure standing-cost reduction.
            linkTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.reconcileLiveSessions() }
            }
        }
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

        // Foreground pid → controller for every tab whose surface is up.
        let pidToController = foregroundPIDs()
        let pids = Array(pidToController.keys)

        let info = await Task.detached(priority: .utility) {
            LiveSessionLinker.inspect(pids: pids)
        }.value

        // Re-validate after the await: a tab may have closed or its foreground
        // process changed during the lsof. Iterate the CURRENT foreground map
        // (not the pre-await snapshot) so we never apply to a closed controller
        // or a reused pid.
        var live: Set<String> = []
        var adopted: Set<String> = []   // conversations already claimed this pass
        for (pid, controller) in foregroundPIDs() {
            // `info` was captured before the await; only trust it for a pid that
            // still maps to the SAME controller, so a pid reused by the OS in
            // the window can't mis-attribute the inspected data.
            guard pidToController[pid] === controller else { continue }
            if controller.base.agent == .shell {
                // A bare shell tab: adopt the agent it hand-launched (or revert
                // to shell when none is running). If another shell tab in the
                // same room already claimed this conversation this pass, keep
                // this one a shell — two tabs must not share one identity.
                var detected = detectConversation(for: info[pid])
                if let d = detected, adopted.contains(d.id) { detected = nil }
                controller.applyDetectedSession(detected)
                if let detected { adopted.insert(detected.id); live.insert(detected.id) }
            } else {
                // Opened as a concrete agent (resume): identity is FIXED — never
                // let cwd+recency detection repoint it to a different session in
                // the same room. It's live while an agent process runs in it.
                if agentRunning(info[pid]) { live.insert(controller.base.id) }
            }
        }
        if liveConversationIDs != live { liveConversationIDs = live }
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

    private func foregroundPIDs() -> [Int32: TerminalTabWindowController] {
        var out: [Int32: TerminalTabWindowController] = [:]
        for c in controllers {
            guard let surface = c.holder.surfaceView?.surface else { continue }
            let pid = ghostty_surface_foreground_pid(surface)
            if pid > 0 { out[Int32(pid)] = c }
        }
        return out
    }

    /// Synchronous live detection (used by `snapshot()`): controller → the
    /// agent conversation it's running, if any. Cheap `lsof` of a handful of
    /// pids — fine on the save-group click.
    private func detectLiveConversations() -> [ObjectIdentifier: Conversation] {
        let pidToController = foregroundPIDs()
        guard !pidToController.isEmpty else { return [:] }
        let info = LiveSessionLinker.inspect(pids: Array(pidToController.keys))
        var out: [ObjectIdentifier: Conversation] = [:]
        for (pid, controller) in pidToController {
            // Only shell tabs adopt; a resumed agent tab keeps its base identity.
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
