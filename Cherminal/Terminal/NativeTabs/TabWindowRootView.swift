import SwiftUI

/// The layout for a single native tab window: a collapsible sidebar (shared
/// registry), this window's one Ghostty surface, and a collapsible context
/// inspector on the right. Selecting a conversation in the sidebar opens or
/// focuses its tab via the coordinator.
struct TabWindowRootView: View {
    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @ObservedObject var holder: TabSurfaceHolder

    /// The tab's effective conversation, observed from the holder so the badge,
    /// title, and context pane follow when the tab adopts a live agent session.
    private var conversation: Conversation { holder.conversation }

    @State private var sidebarMode: SidebarView.Mode = .byRoom
    @State private var showContext = true

    var body: some View {
        NavigationSplitView {
            SidebarView(mode: $sidebarMode, selection: sidebarSelection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            terminal
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: $showContext) {
                    ContextWatchPane(conversation: conversation)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showContext.toggle()
                        } label: {
                            Label("Context", systemImage: "sidebar.right")
                        }
                        .help(showContext ? "Hide context" : "Show context")
                    }
                }
        }
    }

    /// The surface is created lazily once the pane has laid out (see
    /// TabWindowCoordinator), so until then we show the window's background
    /// color — no flash of mis-sized terminal.
    @ViewBuilder
    private var terminal: some View {
        if let surfaceView = holder.surfaceView {
            Ghostty.SurfaceWrapper(surfaceView: surfaceView)
        } else {
            Color.clear
        }
    }

    /// Highlights this window's conversation; a click opens or focuses the
    /// corresponding tab. Missing-from-registry ids produce no write.
    private var sidebarSelection: Binding<Conversation.ID?> {
        Binding(
            get: { conversation.id },
            set: { newID in
                guard let newID, let convo = registry.conversation(id: newID) else { return }
                coordinator.openOrFocus(convo)
            }
        )
    }
}
