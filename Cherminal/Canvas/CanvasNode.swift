import AppKit

/// A node's lifecycle on the canvas. The engine drives these transitions from
/// the viewport + the live budget; each node type decides what they mean for its
/// content (a terminal frees/reattaches its Ghostty surface; a browser would
/// snapshot/suspend its WKWebView; etc.).
enum CanvasNodeState { case live, frozen, culled }

/// One frame on the canvas. The engine is deliberately type-agnostic: it places
/// `view` at `worldFrame` and asks the node to go live / freeze / cull based on
/// the viewport and the live budget. Terminal, browser, phone, and notes are all
/// just conformances — this protocol is the seam that keeps the canvas smooth
/// (bounded live content) AND open-ended (any node type).
///
/// The contract that makes "very very smooth" possible (VISION_2):
///   • goLive()  — attach live content. Only ever called for the bounded live set.
///   • freeze()  — in view but over budget / zoomed too far to read. Drop the
///                 expensive live content; show a cheap frozen representation.
///   • cull()    — off-viewport. Release everything but the card. The backing
///                 process stays alive out-of-band (dtach for terminals) so the
///                 node thaws instantly when it scrolls back.
@MainActor
protocol CanvasNode: AnyObject {
    var id: UUID { get }
    var worldFrame: CGRect { get set }
    var view: NSView { get }
    var state: CanvasNodeState { get }

    func goLive()
    func freeze()
    func cull()
    /// Full teardown — release content AND kill the backing process. Called when
    /// a node is permanently removed (not merely culled off-viewport, which keeps
    /// the process alive for thaw). Default is a no-op.
    func dispose()
}

extension CanvasNode {
    var worldCenter: CGPoint { CGPoint(x: worldFrame.midX, y: worldFrame.midY) }
    func dispose() {}
}
