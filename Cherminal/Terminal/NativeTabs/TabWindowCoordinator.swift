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
    private var controllers: [TerminalTabWindowController] = []

    init(registry: ConversationRegistry, ghostty: Ghostty.App, bookmarks: BookmarksManager) {
        self.registry = registry
        self.ghostty = ghostty
        self.bookmarks = bookmarks
    }

    // MARK: - Open / focus

    /// Open `conversation` in a new native tab, or select its existing tab.
    @discardableResult
    func openOrFocus(_ conversation: Conversation) -> TerminalTabWindowController? {
        if let existing = controllers.first(where: { $0.conversation.id == conversation.id }) {
            select(existing)
            return existing
        }

        guard ghostty.app != nil else {
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
            controller.holder.surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
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
}
