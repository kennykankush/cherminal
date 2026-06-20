import AppKit
import GhosttyKit

/// A terminal frame on the canvas: a real Ghostty surface running a dtach-wrapped
/// shell. The node owns its *content* (the surface) and its *chrome* (header,
/// body, resize handle); it does NOT own its on-screen position — the engine owns
/// the canvas transform and projects `worldFrame` → screen frame. The node just
/// forwards drag events; the engine turns them into world-space moves/resizes and
/// snaps to the grid. dtach keeps the shell alive across freeze/cull so thaw is a
/// reattach, not a cold spawn.
@MainActor
final class TerminalCanvasNode: CanvasNode {
    let id = UUID()
    var worldFrame: CGRect              // logical position in world coords; engine projects it
    private(set) var state: CanvasNodeState = .culled

    let conversation: Conversation
    private let ghosttyApp: ghostty_app_t
    private let streaming: Bool
    private var surface: Ghostty.SurfaceView?

    var onActivate: ((TerminalCanvasNode) -> Void)?
    var onDragBegan: ((TerminalCanvasNode, _ isResize: Bool, NSEvent) -> Void)?
    var onDragMove:  ((TerminalCanvasNode, _ isResize: Bool, NSEvent) -> Void)?
    var onDragEnded: ((TerminalCanvasNode) -> Void)?

    // Chrome (CALayer-cheap; NO SwiftUI, NO material blur over the surface)
    private let container = NodeContainerView()
    private let header = DragAreaView()
    private let contentHost = NSView()
    private let resizeHandle = DragAreaView()
    private let titleLayer = CATextLayer()
    private let dotLayer = CALayer()
    private let frozenLabel = CATextLayer()   // shown as the tile label when not live (zoomed out / off-screen)
    private let headerH: CGFloat = 26

    var view: NSView { container }
    let title: String

    init(conversation: Conversation,
         worldFrame: CGRect,
         ghosttyApp: ghostty_app_t,
         streaming: Bool,
         title: String) {
        self.conversation = conversation
        self.worldFrame = worldFrame
        self.ghosttyApp = ghosttyApp
        self.streaming = streaming
        self.title = title
        container.frame = worldFrame      // initial size; engine sets the projected frame on add
        buildChrome()
        container.onLayout = { [weak self] in self?.layoutChrome() }
    }

    // MARK: Lifecycle (engine-driven)

    func goLive() {
        if surface == nil { spawnSurface() }
        frozenLabel.isHidden = true
        state = .live
        setDot(streaming ? .systemGreen : .systemBlue)
    }
    func freeze() { releaseSurface(); frozenLabel.isHidden = false; state = .frozen; setDot(.systemGray) }
    func cull()   { releaseSurface(); frozenLabel.isHidden = false; state = .culled; setDot(NSColor(calibratedWhite: 0.3, alpha: 1)) }

    /// Permanent teardown — drop the surface AND kill the dtach master. freeze/cull
    /// keep the master alive on purpose; dispose is the only path that reaps it.
    func dispose() { releaseSurface(); _ = Dtach.kill(id: conversation.id) }

    func setActive(_ active: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.layer?.borderColor = active
            ? NSColor.systemOrange.withAlphaComponent(0.9).cgColor
            : NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        container.layer?.borderWidth = active ? 1.8 : 1
        CATransaction.commit()
    }

    // MARK: Surface (dtach-backed)

    private func spawnSurface() {
        var cfg: Ghostty.SurfaceConfiguration
        if streaming {
            cfg = Ghostty.SurfaceConfiguration()
            cfg.workingDirectory = NSHomeDirectory()
            cfg.environmentVariables = BinaryResolver.shared.environment()
            cfg.command = Dtach.wrap(Self.streamCommand, id: conversation.id)
        } else {
            cfg = TerminalCommand.surfaceConfig(for: conversation)
        }
        let s = Ghostty.SurfaceView(ghosttyApp, baseConfig: cfg)
        s.frame = contentHost.bounds
        s.autoresizingMask = [.width, .height]
        contentHost.addSubview(s)
        surface = s
    }

    private func releaseSurface() {
        surface?.removeFromSuperview()   // SurfaceView deinit → ghostty_surface_free (SIGHUPs client; master lives)
        surface = nil
    }

    // MARK: Chrome

    private func buildChrome() {
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor

        header.cursor = .openHand
        header.onMouseDown = { [weak self] e in guard let self else { return }; self.onActivate?(self); self.onDragBegan?(self, false, e) }
        header.onDrag      = { [weak self] e in guard let self else { return }; self.onDragMove?(self, false, e) }
        header.onMouseUp   = { [weak self] _ in guard let self else { return }; self.onDragEnded?(self) }
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        container.addSubview(header)

        titleLayer.string = title
        titleLayer.fontSize = 11
        titleLayer.foregroundColor = NSColor(calibratedWhite: 0.85, alpha: 1).cgColor
        titleLayer.truncationMode = .end
        titleLayer.contentsScale = 2
        header.layer?.addSublayer(titleLayer)

        dotLayer.cornerRadius = 3
        dotLayer.backgroundColor = NSColor.systemGray.cgColor
        header.layer?.addSublayer(dotLayer)

        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1).cgColor
        container.addSubview(contentHost)

        frozenLabel.string = title
        frozenLabel.fontSize = 13
        frozenLabel.foregroundColor = NSColor(calibratedWhite: 0.55, alpha: 1).cgColor
        frozenLabel.alignmentMode = .center
        frozenLabel.truncationMode = .end
        frozenLabel.contentsScale = 2
        frozenLabel.isHidden = true
        contentHost.layer?.addSublayer(frozenLabel)

        resizeHandle.cursor = NSCursor(image: NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil) ?? NSImage(), hotSpot: NSPoint(x: 8, y: 8))
        resizeHandle.onMouseDown = { [weak self] e in guard let self else { return }; self.onActivate?(self); self.onDragBegan?(self, true, e) }
        resizeHandle.onDrag      = { [weak self] e in guard let self else { return }; self.onDragMove?(self, true, e) }
        resizeHandle.onMouseUp   = { [weak self] _ in guard let self else { return }; self.onDragEnded?(self) }
        resizeHandle.wantsLayer = true
        resizeHandle.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        resizeHandle.layer?.cornerRadius = 4
        container.addSubview(resizeHandle)

        layoutChrome()
    }

    private func setDot(_ color: NSColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dotLayer.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    private func layoutChrome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = container.bounds
        header.frame = CGRect(x: 0, y: 0, width: b.width, height: headerH)
        titleLayer.frame = CGRect(x: 10, y: 6, width: max(0, b.width - 40), height: 15)
        dotLayer.frame = CGRect(x: b.width - 16, y: 10, width: 6, height: 6)
        let content = CGRect(x: 1, y: headerH, width: b.width - 2, height: max(0, b.height - headerH - 1))
        contentHost.frame = content
        surface?.frame = contentHost.bounds
        frozenLabel.frame = CGRect(x: 8, y: content.height / 2 - 10, width: max(0, content.width - 16), height: 20)
        resizeHandle.frame = CGRect(x: b.width - 26, y: b.height - 26, width: 24, height: 24)
        CATransaction.commit()
    }

    /// A throttled streamer (perl, ~50 lines/s) to load the renderer for stress tests.
    static let streamCommand = #"perl -e '$|=1;my $i=0;while(1){printf("%6d  canvas v2 streaming line — exercising the ghostty metal renderer\n",$i++);select(undef,undef,undef,0.02);}'"#
}

// MARK: - Small AppKit helpers

/// Flipped so node/world geometry is top-left origin.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A chrome region that forwards mouse down/drag/up. Lives on the header / corner —
/// never over the Ghostty surface (a greedy first responder that owns its clicks).
final class DragAreaView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var cursor: NSCursor?
    override var isFlipped: Bool { true }
    override func resetCursorRects() { if let c = cursor { addCursorRect(bounds, cursor: c) } }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
}

/// The node card's container — re-lays-out its chrome whenever AppKit resizes it,
/// so the header / surface / handle always track the card's real bounds.
final class NodeContainerView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}
