import AppKit
import Combine
import Foundation
import GhosttyKit
import os

/// Owns the set of conversations (and fresh-shell tabs) currently visible
/// in Belvedere's middle pane, plus which one is active. Surfaces stay
/// alive for the lifetime of the tab — switching is a pure visibility
/// swap, not a PTY teardown. Optional `SessionCache` backs auto-save +
/// restore.
@MainActor
final class TabsManager: ObservableObject {
    private static let logger = Logger(subsystem: "dev.hamulia.Belvedere", category: "tabs")

    struct Tab: Identifiable, Equatable {
        let id: UUID
        let conversation: Conversation
        let surfaceView: Ghostty.SurfaceView

        static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeTabID: Tab.ID? {
        didSet {
            guard oldValue != activeTabID else { return }
            focusActiveSurface()
            scheduleSave()
        }
    }

    private let cache: SessionCache?
    private var saveSubscription: AnyCancellable?
    private let saveTrigger = PassthroughSubject<Void, Never>()
    private var suspendSave = false
    private var lastActiveSurface: Ghostty.SurfaceView?

    init(cache: SessionCache? = nil) {
        self.cache = cache
        if cache != nil {
            saveSubscription = saveTrigger
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] in self?.flushSave() }
        }
    }

    // MARK: - Open / close

    func openOrFocus(
        _ conversation: Conversation,
        in ghosttyApp: ghostty_app_t,
        configBuilder: (Conversation) -> Ghostty.SurfaceConfiguration
    ) {
        if let existing = tabs.first(where: { $0.conversation.id == conversation.id }) {
            activate(existing.id)
            return
        }
        let config = configBuilder(conversation)
        let surface = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
        let tab = Tab(id: UUID(), conversation: conversation, surfaceView: surface)
        tabs.append(tab)
        activate(tab.id)
    }

    /// Open a fresh terminal tab — no agent attached. cwd defaults to the
    /// currently active tab's room, falling back to $HOME.
    func openFreshShell(
        in ghosttyApp: ghostty_app_t,
        cwd explicitCWD: URL? = nil,
        configBuilder: (Conversation) -> Ghostty.SurfaceConfiguration
    ) {
        let cwd = explicitCWD
            ?? activeTab?.conversation.roomPath
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let convo = Conversation.shellConversation(cwd: cwd)
        openOrFocus(convo, in: ghosttyApp, configBuilder: configBuilder)
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTabID == id
        // Surface dealloc → libghostty frees the surface → PTY gets SIGHUP.
        tabs.remove(at: index)
        if wasActive {
            if index < tabs.count {
                activate(tabs[index].id)
            } else {
                activate(tabs.last?.id)
            }
        }
        scheduleSave()
    }

    func activate(_ id: Tab.ID?) {
        guard let id else {
            activeTabID = nil
            return
        }
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func tab(for conversationID: Conversation.ID) -> Tab? {
        tabs.first { $0.conversation.id == conversationID }
    }

    var activeTab: Tab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    // MARK: - Persistence

    /// Reopen tabs from a saved snapshot. Conversations missing from the
    /// registry are skipped unless they're synthetic shells, in which case
    /// we rebuild from the stored cwd.
    func restore(
        from state: LastSessionState,
        in ghosttyApp: ghostty_app_t,
        registry: ConversationRegistry,
        configBuilder: (Conversation) -> Ghostty.SurfaceConfiguration
    ) {
        suspendSave = true
        defer {
            suspendSave = false
            scheduleSave()
        }

        for persisted in state.tabs {
            let conversation: Conversation
            if persisted.agentRaw == AgentKind.shell.rawValue {
                conversation = Conversation(
                    id: persisted.conversationID,
                    agent: .shell,
                    roomPath: URL(fileURLWithPath: persisted.roomPath),
                    sessionFile: URL(fileURLWithPath: persisted.roomPath),
                    firstMessageAt: nil,
                    lastActivityAt: .now,
                    messageCount: 0,
                    previewText: nil,
                    state: .live
                )
            } else if let real = registry.conversation(id: persisted.conversationID) {
                conversation = real
            } else {
                continue
            }
            openOrFocus(conversation, in: ghosttyApp, configBuilder: configBuilder)
        }

        if let targetID = state.activeConversationID,
           let target = tabs.first(where: { $0.conversation.id == targetID }) {
            activate(target.id)
        }
    }

    func snapshot() -> [PersistedTab] {
        tabs.map { tab in
            PersistedTab(
                conversationID: tab.conversation.id,
                agentRaw: tab.conversation.agent.rawValue,
                roomPath: tab.conversation.roomPath.path
            )
        }
    }

    private func scheduleSave() {
        guard cache != nil, !suspendSave else { return }
        saveTrigger.send()
    }

    private func flushSave() {
        guard let cache else { return }
        let state = LastSessionState(
            tabs: snapshot(),
            activeConversationID: activeTab?.conversation.id,
            savedAt: .now
        )
        Task.detached(priority: .utility) {
            cache.saveLastSession(state)
        }
    }

    private func focusActiveSurface() {
        let previous = lastActiveSurface
        let current = activeTab?.surfaceView
        lastActiveSurface = current

        #if canImport(AppKit)
        if let current {
            Ghostty.moveFocus(to: current, from: previous === current ? nil : previous)
        } else {
            _ = previous?.resignFirstResponder()
        }
        #endif
    }
}
