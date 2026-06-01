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
    /// The tab's *effective* conversation. Starts as the base identity the tab
    /// was opened with (a shell, or a resumed agent session) and flips when the
    /// live-session linker detects the tab is actually running an agent — so a
    /// `claude` launched by hand inside a shell tab makes the tab become that
    /// conversation. Views observe this, so badge/title/context follow.
    @Published var conversation: Conversation

    init(conversation: Conversation) {
        self.conversation = conversation
        LiveCount.inc("holder")   // ← leak tripwire: should hit 0 when all tabs close
    }

    deinit { LiveCount.dec("holder") }
}

/// One native tab = one `NSWindow` hosting the full 3-pane SwiftUI for a
/// single conversation. Owns that conversation's Ghostty surface (via the
/// holder) for the window's lifetime.
@MainActor
final class TerminalTabWindowController: NSWindowController, NSWindowDelegate {
    /// The identity the tab was opened with. The *effective* conversation
    /// (`holder.conversation`) can differ once the linker detects a live agent.
    let base: Conversation
    let holder: TabSurfaceHolder
    private weak var coordinator: TabWindowCoordinator?

    /// The tab's effective conversation — base, unless adopted to a live one.
    var conversation: Conversation { holder.conversation }

    init(
        conversation: Conversation,
        registry: ConversationRegistry,
        ghostty: Ghostty.App,
        bookmarks: BookmarksManager,
        coordinator: TabWindowCoordinator
    ) {
        self.base = conversation
        self.holder = TabSurfaceHolder(conversation: conversation)
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

        let root = TabWindowRootView(holder: holder)
            .environmentObject(registry)
            .environmentObject(ghostty)
            .environmentObject(bookmarks)
            .environmentObject(AppEnvironment.shared.pins)
            .environmentObject(AppEnvironment.shared.ports)
            .environmentObject(AppEnvironment.shared.caffeine)
            .environmentObject(coordinator)
        window.contentViewController = NSHostingController(rootView: AnyView(root))

        super.init(window: window)
        window.delegate = self
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
        let target = detected ?? base
        guard holder.conversation.id != target.id else { return }
        clog("tabs", "adopt id=\(target.id) agent=\(target.agent.rawValue) (was \(holder.conversation.id))")
        holder.conversation = target
        window?.title = target.roomName
    }
}
