import SwiftUI
import GhosttyKit

@main
struct BelvedereApp: App {
    @NSApplicationDelegateAdaptor(BelvedereAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Belvedere's windows are AppKit-managed native macOS tabs (see
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
            }
    }
}

/// Drives the app lifecycle. Named distinctly from the lifted `AppDelegate`
/// stub so the vendored Ghostty code's `as? AppDelegate` casts still return
/// nil and bail (Belvedere doesn't use those controller-coupled features).
final class BelvedereAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
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
        let env = AppEnvironment.shared
        Task { @MainActor in
            await env.registry.bootstrap()
            if env.coordinator.isEmpty {
                env.coordinator.openFreshShell()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
