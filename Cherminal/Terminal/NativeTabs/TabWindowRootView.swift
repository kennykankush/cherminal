import SwiftUI

/// The layout for a single native tab window: a collapsible sidebar (shared
/// registry), this window's one Ghostty surface, and a collapsible context
/// inspector on the right. Selecting a conversation in the sidebar opens or
/// focuses its tab via the coordinator.
struct TabWindowRootView: View {
    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @EnvironmentObject private var caffeine: CaffeineManager
    @ObservedObject var workspace: Workspace

    /// The active pane's conversation drives the title, sidebar highlight, and
    /// context pane. (Coordinator @Published changes re-render this view when an
    /// adoption flips a pane's identity.)
    private var conversation: Conversation? { workspace.activePane?.conversation }

    // App-wide, persisted — NOT per-window @State, so every tab shows the same
    // sidebar mode / inspector visibility instead of each tab remembering its
    // own (which made the mode look random when switching tabs).
    @AppStorage("cherminal.sidebarMode") private var sidebarMode: SidebarView.Mode = .byRecent
    @AppStorage("cherminal.showContext") private var showContext = true

    var body: some View {
        NavigationSplitView {
            SidebarView(mode: $sidebarMode, selection: sidebarSelection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            TerminalGridView(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: $showContext) {
                    ContextWatchPane(conversation: conversation)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
                }
                // Top-right cluster: coffee (keep-awake), then Context.
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            caffeine.toggle()
                        } label: {
                            Label("Keep awake",
                                  systemImage: caffeine.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                        }
                        .help(caffeine.active ? "Keeping this Mac awake — click to allow sleep"
                                              : "Keep this Mac awake (caffeinate)")
                        .foregroundStyle(caffeine.active ? AnyShapeStyle(CHM.Color.accent) : AnyShapeStyle(.primary))

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


    /// Highlights this window's active conversation; a click opens or focuses the
    /// corresponding tab. Missing-from-registry ids produce no write.
    private var sidebarSelection: Binding<Conversation.ID?> {
        Binding(
            get: { conversation?.id },
            set: { newID in
                guard let newID, let convo = registry.conversation(id: newID) else { return }
                // Defer to the next runloop: opening a tab mutates published
                // state + AppKit windows, and doing that synchronously inside
                // the List's selection commit re-enters the NSTableView delegate
                // (the "reentrant operation" warning → eventual crash).
                DispatchQueue.main.async { coordinator.openOrFocus(convo) }
            }
        )
    }
}
