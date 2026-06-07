import SwiftUI
import AppKit
import GhosttyKit

@main
struct CherminalApp: App {
    @NSApplicationDelegateAdaptor(CherminalAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Cherminal's windows are AppKit-managed native macOS tabs (see
        // TabWindowCoordinator), so there is no SwiftUI WindowGroup. `Settings`
        // is a valid no-op scene that still gives us the standard app menus.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Tab") {
                        AppEnvironment.shared.coordinator.openFreshShell()
                    }
                    .keyboardShortcut("t", modifiers: .command)
                }
                // Tab navigation. These live in the app menu so AppKit routes
                // the shortcuts app-wide (the key reaches the menu before the
                // focused Ghostty surface, so the terminal never swallows them).
                CommandMenu("Tabs") {
                    Button("Show Next Tab") {
                        AppEnvironment.shared.coordinator.selectNextTab()
                    }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    Button("Show Previous Tab") {
                        AppEnvironment.shared.coordinator.selectPreviousTab()
                    }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    Divider()
                    ForEach(1...9, id: \.self) { n in
                        Button(n == 9 ? "Last Tab" : "Tab \(n)") {
                            AppEnvironment.shared.coordinator.selectTab(number: n)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    }
                }
            }
    }
}

/// Drives the app lifecycle. Named distinctly from the lifted `AppDelegate`
/// stub so the vendored Ghostty code's `as? AppDelegate` casts still return
/// nil and bail (Cherminal doesn't use those controller-coupled features).
final class CherminalAppDelegate: NSObject, NSApplicationDelegate {
    /// True when the process is hosting a unit-test bundle. We skip all
    /// real launch work (ghostty_init, env prewarm, registry bootstrap) so the
    /// logic tests run against a quiet host instead of booting a terminal.
    private var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        // First thing: stand up diagnostics + crash capture so we record
        // everything, including faults in libghostty's C layer (which often
        // produce no standard crash report).
        Diagnostics.bootstrap()

        // Point libghostty at our bundled resources (terminfo etc.). Without
        // this, libghostty can't find the xterm-ghostty terminfo and falls back
        // to TERM=xterm-256color for spawned surfaces — which lacks bracketed
        // paste (so multi-line paste into agent TUIs is flagged "unsafe" and
        // silently dropped) and the kitty keyboard protocol (Shift+Enter). The
        // bundled folder is Contents/Resources/ghostty (see project.yml). Set
        // before ghostty_init; respect an existing value so it stays overridable.
        if getenv("GHOSTTY_RESOURCES_DIR") == nil,
           let resources = Bundle.main.resourcePath {
            setenv("GHOSTTY_RESOURCES_DIR", resources + "/ghostty", 1)
        }

        // libghostty has process-wide globals that must be initialized before
        // any other ghostty API call — segfaults otherwise. Must run before
        // AppEnvironment.shared (which constructs Ghostty.App) is first touched.
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            fatalError("ghostty_init failed")
        }
        // Capture the user's shell-resolved PATH so bare command names resolve
        // the same way they do in the user's terminal.
        BinaryResolver.shared.prewarm()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        let env = AppEnvironment.shared
        env.metrics.startIfEnabled()   // headless perf CSV (off unless cherminal.metrics)
        installTabShortcutMonitor()
        // Defer the Groups menu: SwiftUI installs its own main menu *after*
        // this callback, so an insert here gets wiped. The next runloop tick
        // (and every activation, see applicationDidBecomeActive) re-asserts it.
        DispatchQueue.main.async { [weak self] in self?.installGroupsMenu() }

        // Restore last session's tabs. Shell tabs need no registry, so a saved
        // session of only shells (or nothing saved) opens instantly — the
        // terminal never waits behind the disk scan. Agent tabs need the cache
        // snapshot first so they resume with the right sessionFile (the context
        // gauge reads it), so those restore inside the Task after the (cheap)
        // cache load. Ghostty is ready synchronously once AppEnvironment is built.
        //
        // Honor a persisted "Don't Reopen" here too, not only at quit. The quit
        // handler is the only *other* place that clears the session, so a crash or
        // force-quit (which skips applicationShouldTerminate) would otherwise
        // restore the old tabs for a user who chose "Don't ask again + Don't
        // Reopen." Must run BEFORE the sweep: sweepDtachSockets() keeps masters
        // referenced by savedSessionTabs(), so clearing first lets the sweep reap
        // the now-unwanted agents instead of leaving them running invisibly.
        if env.coordinator.reopenChoice == .dontReopen {
            env.coordinator.clearSavedSession()
        }

        // Reap any dtach masters nothing will reattach (crash orphans / stale
        // sockets, and — per above — dont-reopen sessions) before restoring.
        env.coordinator.sweepDtachSockets()

        let saved = env.coordinator.savedSessionTabs()
        let needsCache = saved.contains { $0.agentRaw != AgentKind.shell.rawValue }
        if env.coordinator.isEmpty && !needsCache {
            if !env.coordinator.restoreSession() {
                env.coordinator.openFreshShell()
            }
        }

        Task { @MainActor in
            // Detached agents are always agents, so resolving them needs the
            // cache even when the restored tabs were shell-only.
            let hasDetached = !env.coordinator.savedDetached().isEmpty
            if (env.coordinator.isEmpty && needsCache) || hasDetached {
                await env.registry.loadCacheSnapshot()
            }
            if env.coordinator.isEmpty && needsCache {
                if !env.coordinator.restoreSession() {
                    env.coordinator.openFreshShell()
                }
            }
            // Rebuild the rail from masters that are still alive.
            if hasDetached { env.coordinator.restoreDetachedAgents() }
            // Full reconcile + watcher (cache load above is idempotent-skipped).
            await env.registry.bootstrap()
        }
    }

    /// Persist the open tabs so the next launch reopens them. Done in
    /// `shouldTerminate` (not `willTerminate`) because macOS closes every window
    /// — each firing `windowWillClose`, which empties the controller list —
    /// *before* `willTerminate`, so a snapshot taken there is always empty. Here
    /// the tabs are still alive. A crash skips this, leaving the prior snapshot.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningTests else { return .terminateNow }
        let coordinator = AppEnvironment.shared.coordinator

        // Capture what's open now. persistSession keeps the last non-empty
        // snapshot if we're quitting from the placeholder (nothing open), so the
        // prompt still offers to reopen the tabs you last had.
        coordinator.persistSession()
        let count = coordinator.savedSessionTabs().count

        // "Save windows"-style reopen decision. Nothing to reopen → just quit.
        let reply: NSApplication.TerminateReply
        if count == 0 {
            reply = .terminateNow
        } else {
            switch coordinator.reopenChoice {
            case .reopen:     reply = .terminateNow                 // session kept as-is
            case .dontReopen: coordinator.clearSavedSession(); reply = .terminateNow
            case .ask:        reply = promptReopen(count: count, coordinator: coordinator)
            }
        }

        // Mark teardown ONLY when actually quitting, so a cancelled quit doesn't
        // leave isTerminating set (which would stop window closes from parking
        // agents in the rail). Durable breadcrumb: a clean quit logs this line;
        // a crash/SIGKILL just stops with no such line.
        if reply == .terminateNow {
            coordinator.beginTermination()
            clog("app", "clean termination (reopen=\(count) tabs, choice=\(coordinator.reopenChoice.rawValue))")
        } else if coordinator.isEmpty {
            // Quit cancelled, but this was a close-the-last-window quit so the
            // window is already gone — reopen the tabs so we're not left running
            // with no window (and nothing to click).
            coordinator.restoreSession()
        }
        return reply
    }

    /// "Reopen your N tabs next time?" dialog (macOS save-windows style). Cancel
    /// aborts the quit; "Don't ask again" persists the choice so it's silent
    /// thereafter.
    @MainActor
    private func promptReopen(count: Int, coordinator: TabWindowCoordinator) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Reopen your \(count) tab\(count == 1 ? "" : "s") next time?"
        alert.informativeText = "Cherminal can reopen the tabs you have open the next time you launch it."
        alert.addButton(withTitle: "Reopen")        // .alertFirstButtonReturn (default / Return)
        alert.addButton(withTitle: "Don't Reopen")  // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")        // .alertThirdButtonReturn (Esc)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        let remember = alert.suppressionButton?.state == .on

        switch response {
        case .alertFirstButtonReturn:               // Reopen
            if remember { coordinator.setReopenChoice(.reopen) }
            return .terminateNow                    // session already persisted
        case .alertSecondButtonReturn:              // Don't Reopen
            if remember { coordinator.setReopenChoice(.dontReopen) }
            coordinator.clearSavedSession()
            return .terminateNow
        default:                                    // Cancel
            return .terminateCancel
        }
    }

    // MARK: - Groups menu
    //
    // Saved tab-groups live in the menu bar (per the inspector restructure).
    // Built in AppKit with explicit targets/actions because SwiftUI `.commands`
    // don't reliably route to this app's AppKit windows. Rebuilt on open so it
    // reflects the current bookmark set.

    private var groupsMenu: NSMenu?
    private var groupsMenuItem: NSMenuItem?

    /// Insert the Groups menu just left of Window. Idempotent and re-callable:
    /// if SwiftUI has rebuilt/replaced the main menu and dropped our item, this
    /// re-adds it; if it's already attached, this is a no-op. Safe to call on
    /// every activation.
    private func installGroupsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if let groupsMenuItem, mainMenu.items.contains(groupsMenuItem) { return }

        let menu = NSMenu(title: "Groups")
        menu.delegate = self
        let item = NSMenuItem()
        item.title = "Groups"
        item.submenu = menu
        // Sit just left of the Window menu — found by reference, not title, so
        // it's correct on non-English locales (fall back to appending).
        let idx = mainMenu.items.firstIndex { $0.submenu === NSApp.windowsMenu }
        if let idx { mainMenu.insertItem(item, at: idx) } else { mainMenu.addItem(item) }
        groupsMenu = menu
        groupsMenuItem = item
        MainActor.assumeIsolated { rebuildGroupsMenu() }
    }

    /// Re-assert the Groups menu after a SwiftUI menu rebuild can have removed it.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isRunningTests else { return }
        installGroupsMenu()
    }

    @MainActor
    private func rebuildGroupsMenu() {
        guard let menu = groupsMenu else { return }
        menu.removeAllItems()
        let save = NSMenuItem(title: "Save Open Tabs as Group",
                              action: #selector(saveGroupAction), keyEquivalent: "")
        save.target = self
        save.isEnabled = AppEnvironment.shared.coordinator.tabCount > 0
        menu.addItem(save)
        menu.addItem(.separator())

        let bookmarks = AppEnvironment.shared.bookmarks.bookmarks
        if bookmarks.isEmpty {
            let none = NSMenuItem(title: "No Saved Groups", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for g in bookmarks {
                let sub = NSMenu()
                let open = NSMenuItem(title: "Open", action: #selector(openGroupAction(_:)), keyEquivalent: "")
                open.target = self; open.representedObject = g.id
                sub.addItem(open)
                let del = NSMenuItem(title: "Delete", action: #selector(deleteGroupAction(_:)), keyEquivalent: "")
                del.target = self; del.representedObject = g.id
                sub.addItem(del)
                let name = g.name.isEmpty ? "Untitled" : g.name
                let item = NSMenuItem(title: "\(name) (\(g.tabs.count))", action: nil, keyEquivalent: "")
                item.submenu = sub
                menu.addItem(item)
            }
        }
    }

    @objc private func saveGroupAction() {
        MainActor.assumeIsolated {
            let env = AppEnvironment.shared
            let tabs = env.coordinator.snapshot()
            if !tabs.isEmpty { env.bookmarks.create(name: "", tabs: tabs) }
        }
    }

    @objc private func openGroupAction(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let id = sender.representedObject as? UUID else { return }
            let env = AppEnvironment.shared
            guard let g = env.bookmarks.bookmarks.first(where: { $0.id == id }) else { return }
            env.bookmarks.open(g, registry: env.registry, coordinator: env.coordinator)
        }
    }

    @objc private func deleteGroupAction(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let id = sender.representedObject as? UUID else { return }
            AppEnvironment.shared.bookmarks.delete(id)
        }
    }

    // MARK: - Tab keyboard shortcuts
    //
    // Cherminal's windows are AppKit NSWindows, not SwiftUI scene windows, and
    // the only Scene is `Settings`. SwiftUI `.commands` shortcuts don't route to
    // a key AppKit window (even ⌘T was dead), so we intercept the keys with a
    // local monitor and drive the coordinator directly. Guarded to our own
    // windows so the Settings window / other apps' shortcuts are untouched.

    private var shortcutMonitor: Any?

    private func installTabShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors fire on the main thread before menu/responder
            // dispatch; consuming (returning nil) keeps the key from reaching
            // the focused terminal surface.
            let handled = MainActor.assumeIsolated { CherminalAppDelegate.handleTabShortcut(event) }
            return handled ? nil : event
        }
    }

    @MainActor
    private static func handleTabShortcut(_ event: NSEvent) -> Bool {
        // Only when one of our terminal tab windows is key.
        guard let key = NSApp.keyWindow,
              key.tabbingIdentifier == "belvedere-native",
              let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let coordinator = AppEnvironment.shared.coordinator

        if mods == .command {
            if chars == "t" { coordinator.openFreshShell(); return true }
            if chars == "d" { coordinator.addPaneToActiveWindow(); return true }   // split: add pane
            if chars == "`" { coordinator.focusNextPane(); return true }           // cycle panes
            if let n = Int(chars), (1...9).contains(n) { coordinator.selectTab(number: n); return true }
        } else if mods == [.command, .shift] {
            if chars == "]" || chars == "}" { coordinator.selectNextTab(); return true }
            if chars == "[" || chars == "{" { coordinator.selectPreviousTab(); return true }
            if chars == "w" || chars == "W" { coordinator.closeActivePane(); return true }   // close pane
        }
        return false
    }

    /// Quit when the last window closes, like normal Mac software — closing the
    /// last tab routes to applicationShouldTerminate (the reopen prompt), it does
    /// NOT pop a placeholder you have to close again. The placeholder is no longer
    /// shown on close (see TabWindowCoordinator.windowClosed).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension CherminalAppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === groupsMenu else { return }
        MainActor.assumeIsolated { rebuildGroupsMenu() }
    }
}
