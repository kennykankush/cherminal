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
        // Open the first window immediately — Ghostty is ready synchronously
        // once AppEnvironment is built, so the terminal must not wait behind the
        // session scan. The sidebar then fills in as bootstrap streams results.
        if env.coordinator.isEmpty {
            env.coordinator.openFreshShell()
        }
        installTabShortcutMonitor()
        Task { @MainActor in
            await env.registry.bootstrap()
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
            if let n = Int(chars), (1...9).contains(n) { coordinator.selectTab(number: n); return true }
        } else if mods == [.command, .shift] {
            if chars == "]" || chars == "}" { coordinator.selectNextTab(); return true }
            if chars == "[" || chars == "{" { coordinator.selectPreviousTab(); return true }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
