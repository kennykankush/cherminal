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

    /// Polls the live-session linker while any tab is open.
    private var linkTimer: Timer?

    init(registry: ConversationRegistry, ghostty: Ghostty.App, bookmarks: BookmarksManager) {
        self.registry = registry
        self.ghostty = ghostty
        self.bookmarks = bookmarks
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
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self,
                  let controller,
                  controller.holder.surfaceView == nil,
                  let app = self.ghostty.app else { return }
            let config = TerminalCommand.surfaceConfig(for: conversation)
            clog("tabs", "spawn surface id=\(conversation.id) cwd=\(config.workingDirectory ?? "nil") cmd=\(config.command ?? "default-shell")")
            controller.holder.surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
            clog("tabs", "spawn surface ok id=\(conversation.id)")
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
        return controllers.map { c in
            let convo = detected[ObjectIdentifier(c)] ?? c.conversation
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
    }

    private func select(_ controller: TerminalTabWindowController) {
        guard let window = controller.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.tabGroup?.selectedWindow = window
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
            linkTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
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
        // Foreground pid → controller for every tab whose surface is up.
        let pidToController = foregroundPIDs()
        let pids = Array(pidToController.keys)

        let info = await Task.detached(priority: .utility) {
            LiveSessionLinker.inspect(pids: pids)
        }.value

        var live: Set<String> = []
        for (pid, controller) in pidToController {
            let detected = detectConversation(for: info[pid])
            controller.applyDetectedSession(detected)
            if let detected { live.insert(detected.id) }
        }
        if liveConversationIDs != live { liveConversationIDs = live }
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
        if let path = info.openSessionFile,
           let match = registry.conversations.first(where: { $0.sessionFile.path == path }) {
            return match
        }
        guard info.command.lowercased().hasPrefix("claude"), let cwd = info.cwd else { return nil }
        return registry.conversations
            .filter { $0.agent == .claudeCode && $0.roomPath.path == cwd }
            .max { $0.lastActivityAt < $1.lastActivityAt }
    }
}
