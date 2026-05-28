import AppKit
import SwiftUI
import GhosttyKit

/// One native tab = one `NSWindow` hosting the full 3-pane SwiftUI for a
/// single conversation. Owns that conversation's Ghostty surface for the
/// window's lifetime.
@MainActor
final class TerminalTabWindowController: NSWindowController, NSWindowDelegate {
    let conversation: Conversation
    let surfaceView: Ghostty.SurfaceView
    private weak var coordinator: TabWindowCoordinator?

    init(
        conversation: Conversation,
        surfaceView: Ghostty.SurfaceView,
        registry: ConversationRegistry,
        ghostty: Ghostty.App,
        bookmarks: BookmarksManager,
        coordinator: TabWindowCoordinator
    ) {
        self.conversation = conversation
        self.surfaceView = surfaceView
        self.coordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // All Belvedere windows share one tab group.
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

        let root = TabWindowRootView(conversation: conversation, surfaceView: surfaceView)
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
