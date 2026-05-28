import AppKit

/// Stub types lifted from Ghostty.app's controller architecture. Cherminal
/// never instantiates these — every `as?` downcast in the lifted code will
/// return nil and the surrounding guard statements bail out, which gives
/// us the correct no-op behavior for features Cherminal doesn't support.

/// Ghostty.app's base window controller. Cherminal uses SwiftUI windows
/// without an NSWindowController of its own, so this only exists to satisfy
/// type lookups.
class BaseTerminalController: NSWindowController {
    var surfaceTree: SurfaceTreeStub { SurfaceTreeStub() }
    var focusedSurface: Ghostty.SurfaceView? { nil }
    var titleOverride: String? {
        get { nil }
        set { _ = newValue }
    }

    var focusFollowsMouse: Bool { false }
    var commandPaletteIsShowing: Bool { false }

    @objc func changeTabTitle(_ sender: Any?) {}
    func toggleBackgroundOpacity() {}
    func promptTabTitle() {}
}

/// Stub for Ghostty.app's restore-from-session error type. Cherminal doesn't
/// persist sessions, so the only case we provide is the one referenced by
/// the lifted decoder.
enum TerminalRestoreError: Error {
    case delegateInvalid
}

/// Stand-in for Ghostty.app's SplitTree. Cherminal has no splits, so the
/// stub returns absent nodes and unhandled navigation requests.
struct SurfaceTreeStub {
    var isSplit: Bool { false }
    var root: SurfaceTreeNodeStub? { nil }
    func focusTarget(for direction: SplitTree<Ghostty.SurfaceView>.FocusDirection,
                     from node: SurfaceTreeNodeStub) -> Ghostty.SurfaceView? { nil }
}

struct SurfaceTreeNodeStub {
    func node(view: Ghostty.SurfaceView) -> SurfaceTreeNodeStub? { nil }
}

/// Stand-in for Ghostty.app's generic SplitTree<T>. Only the FocusDirection
/// type is referenced by the lifted code; we surface it as a passthrough.
enum SplitTree<ViewType> {
    enum FocusDirection {
        case previous, next
        case spatial(Spatial)
        enum Spatial { case up, down, left, right }
    }
}

/// Ghostty.app's window subclass. Cherminal uses default NSWindow; this
/// stub lets the lifted Fullscreen.swift compile.
class TerminalWindow: NSWindow {
    func isTabBar(_ accessory: NSTitlebarAccessoryViewController) -> Bool { false }
}

/// macOS 26.0-only workaround target class. Never instantiated.
class HiddenTitlebarTerminalWindow: TerminalWindow {}
