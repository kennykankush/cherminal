import AppKit
import Combine
import SwiftUI
import os

/// Cherminal doesn't ship a classical AppDelegate (SwiftUI @main drives the
/// lifecycle). This class exists only so that the lifted Ghostty source —
/// which performs `NSApplication.shared.delegate as? AppDelegate` casts —
/// compiles. Cherminal never sets this as the actual app delegate, so every
/// such cast returns nil at runtime and the surrounding guards bail. The
/// methods/properties below therefore never actually execute; they only
/// need to satisfy the type system.
class AppDelegate: NSObject, NSApplicationDelegate {
    static let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "ghostty")

    var undoManager: UndoManager? { nil }
    var ghostty: Ghostty.App { fatalError("Cherminal stub: ghostty accessed on AppDelegate") }

    @objc func checkForUpdates(_ sender: Any?) {}
    @objc func closeAllWindows(_ sender: Any?) {}
    @objc func toggleVisibility(_ sender: Any?) {}
    @objc func syncFloatOnTopMenu(_ window: NSWindow?) {}
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}
    @objc func toggleQuickTerminal(_ sender: Any?) {}
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }
}

/// Ghostty's SurfaceView references a SecureInput singleton to mirror macOS
/// secure-input state. v0.1 ships without secure-input UX, so these are
/// no-op stubs that satisfy the call sites.
final class SecureInput: ObservableObject {
    static let shared = SecureInput()
    @Published private(set) var enabled: Bool = false
    private init() {}
    func setScoped(_ id: ObjectIdentifier, focused: Bool) {}
    func removeScoped(_ id: ObjectIdentifier) {}
}

struct SecureInputOverlay: View {
    var body: some View { EmptyView() }
}
