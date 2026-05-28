import AppKit
import SwiftUI
import GhosttyKit

/// Holds a tab window's Ghostty surface. Created empty so the surface can be
/// spawned *after* the window's panes have laid out — otherwise the shell (and
/// its startup banner) spawn into a momentarily-squished pane and render at the
/// wrong width.
@MainActor
final class TabSurfaceHolder: ObservableObject {
    @Published var surfaceView: Ghostty.SurfaceView?
}

/// One native tab = one `NSWindow` hosting the full 3-pane SwiftUI for a
/// single conversation. Owns that conversation's Ghostty surface (via the
/// holder) for the window's lifetime.
@MainActor
final class TerminalTabWindowController: NSWindowController, NSWindowDelegate {
    let conversation: Conversation
    let holder = TabSurfaceHolder()
    private weak var coordinator: TabWindowCoordinator?

    init(
        conversation: Conversation,
        registry: ConversationRegistry,
        ghostty: Ghostty.App,
        bookmarks: BookmarksManager,
        coordinator: TabWindowCoordinator
    ) {
        self.conversation = conversation
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

        let root = TabWindowRootView(holder: holder, conversation: conversation)
            .environmentObject(registry)
            .environmentObject(ghostty)
            .environmentObject(bookmarks)
            .environmentObject(coordinator)
        window.contentViewController = NSHostingController(rootView: AnyView(root))

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The native "+" in the tab bar walks the responder chain to this.
    @objc override func newWindowForTab(_ sender: Any?) {
        coordinator?.openFreshShell()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.windowClosed(self)
    }
}
