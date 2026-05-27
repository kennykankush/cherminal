import SwiftUI
import GhosttyKit

@main
struct BelvedereApp: App {
    @StateObject private var registry: ConversationRegistry
    @StateObject private var ghostty: Ghostty.App
    @StateObject private var tabs: TabsManager
    @StateObject private var bookmarks: BookmarksManager

    init() {
        // libghostty has process-wide globals (logging, font discovery,
        // runtime state) that must be initialized before any other API
        // call — segfaults otherwise. Mirrors Ghostty.app's main.swift.
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            fatalError("ghostty_init failed")
        }
        // Capture the user's shell-resolved PATH so the bare command names
        // we hand Ghostty resolve the same way the user's terminal does.
        BinaryResolver.shared.prewarm()

        // One SessionCache shared by every layer that persists state.
        let sharedCache = try? SessionCache()
        _registry = StateObject(wrappedValue: ConversationRegistry(cache: sharedCache))
        _ghostty = StateObject(wrappedValue: Ghostty.App())
        _tabs = StateObject(wrappedValue: TabsManager(cache: sharedCache))
        _bookmarks = StateObject(wrappedValue: BookmarksManager(cache: sharedCache))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(registry)
                .environmentObject(ghostty)
                .environmentObject(tabs)
                .environmentObject(bookmarks)
                .frame(minWidth: 1100, minHeight: 680)
                .task {
                    await registry.bootstrap()
                    restoreLastSession()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") {
                    guard let app = ghostty.app else { return }
                    tabs.openFreshShell(in: app, configBuilder: TerminalCommand.surfaceConfig(for:))
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1400, height: 860)
    }

    /// Rehydrate the previous session's tabs after the registry has loaded
    /// real conversations. Tabs whose conversation is gone (deleted from
    /// disk since last quit) are silently skipped — best effort, not
    /// authoritative.
    private func restoreLastSession() {
        guard let cache = registry.cache,
              let state = cache.loadLastSession(),
              !state.tabs.isEmpty,
              let app = ghostty.app else { return }

        tabs.restore(from: state,
                     in: app,
                     registry: registry,
                     configBuilder: TerminalCommand.surfaceConfig(for:))
    }
}
