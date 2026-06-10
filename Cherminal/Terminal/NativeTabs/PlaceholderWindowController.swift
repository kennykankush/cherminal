import AppKit
import SwiftUI

/// The "no tabs open" home window. Shown when the last conversation tab closes
/// (instead of the app vanishing), so the sidebar stays around and you can pick
/// a conversation or press ⌘T. Closing it (red button / ⌘W) quits — it's the
/// last thing standing, so closing it means "I'm done". Standalone window:
/// `tabbingMode = .disallowed` keeps it out of the conversation tab group so the
/// two never show together.
@MainActor
final class PlaceholderWindowController: NSWindowController, NSWindowDelegate {
    init(
        registry: ConversationRegistry,
        ghostty: Ghostty.App,
        bookmarks: BookmarksManager,
        coordinator: TabWindowCoordinator
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
        window.title = "Cherminal"
        window.titlebarAppearsTransparent = true
        let bg = NSColor(ghostty.config.backgroundColor)
        window.backgroundColor = bg
        window.appearance = NSAppearance(named: bg.isLightColor ? .aqua : .darkAqua)
        window.isRestorable = false
        window.minSize = NSSize(width: 900, height: 560)

        let root = PlaceholderRootView()
            .environmentObject(registry)
            .environmentObject(ghostty)
            .environmentObject(bookmarks)
            .environmentObject(AppEnvironment.shared.pins)
            .environmentObject(AppEnvironment.shared.backgroundAgents)
            .environmentObject(AppEnvironment.shared.ports)
            .environmentObject(AppEnvironment.shared.caffeine)
            .environmentObject(coordinator)
        window.contentViewController = NSHostingController(rootView: AnyView(root))

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Closing the home window quits. The app doesn't auto-quit on
    /// last-window-close (so closing the last *tab* can show this placeholder),
    /// so we terminate explicitly here. Not called during app termination —
    /// that drives `windowWillClose`, not `windowShouldClose` — so no recursion.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

/// The placeholder's content: the same sidebar (so conversations are one click
/// away) beside a calm empty state. Selecting a conversation opens it as a real
/// tab; the coordinator then hides this window.
private struct PlaceholderRootView: View {
    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @AppStorage("cherminal.sidebarMode") private var sidebarMode: SidebarView.Mode = .byRecent

    var body: some View {
        NavigationSplitView {
            SidebarView(mode: $sidebarMode, selection: selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        }
    }

    /// No row stays selected here; a pick just opens that conversation as a tab.
    /// Deferred to the next runloop like every other sidebar action, so it never
    /// re-enters the List's table delegate.
    private var selection: Binding<Conversation.ID?> {
        Binding(
            get: { nil },
            set: { newID in
                guard let newID, let convo = registry.conversation(id: newID) else { return }
                DispatchQueue.main.async { coordinator.openOrFocus(convo) }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: CHM.Space.md) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No tabs open")
                .font(CHM.Font.bodyEmphasis)
                .foregroundStyle(.secondary)
            Text("Pick a conversation, or press ⌘T for a new tab.")
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
            Button {
                coordinator.openFreshShell()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
