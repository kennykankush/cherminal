import SwiftUI

/// Top-level content for Belvedere's single window. Three panes:
/// sidebar (conversations), middle (bookmarks + tabs + Ghostty surface),
/// and context (info about the active tab).
struct RootView: View {
    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var tabs: TabsManager
    @State private var sidebarMode: SidebarView.Mode = .byRoom

    var body: some View {
        NavigationSplitView {
            SidebarView(mode: $sidebarMode, selection: sidebarSelection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } content: {
            TerminalPane()
                .navigationSplitViewColumnWidth(min: 480, ideal: 760)
        } detail: {
            ContextWatchPane(conversation: tabs.activeTab?.conversation)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Sidebar selection mirrors the active tab's conversation id. Setting
    /// the binding (via a sidebar click) opens or focuses a tab via
    /// TabsManager. Shell tabs and missing-from-registry conversations
    /// produce no binding write.
    private var sidebarSelection: Binding<Conversation.ID?> {
        Binding(
            get: { tabs.activeTab?.conversation.id },
            set: { newID in
                guard let newID, let conversation = registry.conversation(id: newID) else { return }
                guard let app = ghostty.app else { return }
                tabs.openOrFocus(conversation, in: app, configBuilder: TerminalCommand.surfaceConfig(for:))
            }
        )
    }
}
