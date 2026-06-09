import AppKit
import SwiftUI
import GhosttyKit

/// Holds a tab window's Ghostty surface. Created empty so the surface can be
/// spawned *after* the window's panes have laid out — otherwise the shell (and
/// its startup banner) spawn into a momentarily-squished pane and render at the
/// wrong width.
/// One native tab = one `NSWindow` hosting the full SwiftUI for a workspace.
/// Owns a `Workspace` (a grid of panes — one pane today, N after the grid
/// lands). `holder` is a compatibility shim returning the active pane so the
/// pre-grid coordinator code keeps working unchanged.
@MainActor
final class TerminalTabWindowController: NSWindowController, NSWindowDelegate {
    /// The identity the window was opened with. The *effective* conversation
    /// (`holder.conversation`) can differ once the linker detects a live agent.
    let base: Conversation
    let workspace: Workspace
    private weak var coordinator: TabWindowCoordinator?
    /// Inline tab-title editing (double-click the tab). The editor installs its
    /// own click monitor scoped to this window's tab bar; we just supply the
    /// delegate. Lives as long as the controller.
    private var titleEditor: TabTitleEditor?

    /// The active pane. Shim for the pre-grid call sites (`controller.holder`).
    var holder: Pane { workspace.activePane ?? workspace.panes[0] }

    /// The window's effective conversation — base, unless adopted to a live one.
    var conversation: Conversation { holder.conversation }

    init(
        conversation: Conversation,
        registry: ConversationRegistry,
        ghostty: Ghostty.App,
        bookmarks: BookmarksManager,
        coordinator: TabWindowCoordinator
    ) {
        self.base = conversation
        let pane = Pane(conversation: conversation)
        let workspace = Workspace(panes: [pane])
        self.workspace = workspace
        self.coordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // All Cherminal windows share one tab group.
        window.tabbingIdentifier = "belvedere-native"
        window.tabbingMode = .preferred
        window.title = conversation.roomName
        window.titlebarAppearsTransparent = true

        // Seamless chrome: paint the window (titlebar + native tab bar area)
        // with the user's actual Ghostty background color so it reads as one
        // continuous surface with the terminal, instead of the default grey
        // titlebar material.
        let bg = NSColor(ghostty.config.backgroundColor)
        window.backgroundColor = bg
        window.appearance = NSAppearance(named: bg.isLightColor ? .aqua : .darkAqua)

        // Open large and centered. (Later tabs joining the group inherit the
        // group's frame, so this only takes effect for the first window.)
        // isRestorable = false stops macOS from reviving a stale small frame.
        window.isRestorable = false
        window.minSize = NSSize(width: 900, height: 560)
        if let visible = NSScreen.main?.visibleFrame {
            let size = NSSize(
                width: min(1600, visible.width * 0.9),
                height: min(1000, visible.height * 0.9)
            )
            window.setContentSize(size)
        }
        window.center()

        let root = TabWindowRootView(workspace: workspace)
            .environmentObject(registry)
            .environmentObject(ghostty)
            .environmentObject(bookmarks)
            .environmentObject(AppEnvironment.shared.pins)
            .environmentObject(AppEnvironment.shared.labels)
            .environmentObject(AppEnvironment.shared.ports)
            .environmentObject(AppEnvironment.shared.caffeine)
            .environmentObject(coordinator)
        window.contentViewController = NSHostingController(rootView: AnyView(root))

        super.init(window: window)
        window.delegate = self
        titleEditor = TabTitleEditor(hostWindow: window, delegate: self)
        LiveCount.inc("window")
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { LiveCount.dec("window") }

    /// The native "+" in the tab bar walks the responder chain to this.
    @objc override func newWindowForTab(_ sender: Any?) {
        coordinator?.openFreshShell()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.windowClosed(self)
    }

    /// Apply the linker's verdict: adopt `detected` as the effective identity
    /// (a hand-launched agent), or fall back to `base` when nothing live is
    /// running (the agent exited and we're back at a shell). Idempotent.
    func applyDetectedSession(_ detected: Conversation?) {
        holder.applyDetectedSession(detected)
        refreshTitle()
    }

    // MARK: - Tab title (the one title law)

    /// The tab's title: the user's rename when set, else the active pane's
    /// room. EVERY title write goes through here — adoption and the reconcile
    /// used to write `window.title` raw, which would have stomped a rename
    /// within seconds.
    func refreshTitle() {
        window?.title = workspace.name ?? holder.conversation.roomName
    }

    /// Begin the inline tab rename for THIS tab (the Tabs → Rename Tab path;
    /// double-click reaches the editor directly). Falls back to the prompt
    /// when the inline editor can't attach (e.g. tab bar hidden).
    func beginRename() {
        guard let window else { return }
        if titleEditor?.beginEditing(for: window) != true {
            coordinator?.promptRenameTab(window: window)
        }
    }
}

// MARK: - TabTitleEditorDelegate (inline rename on tab double-click)

// @preconcurrency: the vendored protocol is nonisolated, but the editor only
// calls it from AppKit main-thread contexts (event monitor, field editor) —
// asserted at runtime by the main-actor isolation.
extension TerminalTabWindowController: @preconcurrency TabTitleEditorDelegate {
    func tabTitleEditor(_ editor: TabTitleEditor, canRenameTabFor targetWindow: NSWindow) -> Bool {
        // Only our terminal tabs — never the placeholder or foreign windows.
        targetWindow.tabbingIdentifier == "belvedere-native"
    }

    func tabTitleEditor(_ editor: TabTitleEditor, titleFor targetWindow: NSWindow) -> String {
        // Seed with what's on screen (rename or room) — targetWindow may be a
        // sibling tab, and its title is kept fresh by refreshTitle.
        targetWindow.title
    }

    func tabTitleEditor(_ editor: TabTitleEditor, didCommitTitle editedTitle: String, for targetWindow: NSWindow) {
        coordinator?.renameTab(window: targetWindow, to: editedTitle)
    }

    func tabTitleEditor(_ editor: TabTitleEditor, performFallbackRenameFor targetWindow: NSWindow) {
        coordinator?.promptRenameTab(window: targetWindow)
    }

    func tabTitleEditor(_ editor: TabTitleEditor, didFinishEditing targetWindow: NSWindow) {
        // Hand the keyboard back to the terminal the user was in.
        coordinator?.restoreFocus(inWindow: targetWindow)
    }
}
