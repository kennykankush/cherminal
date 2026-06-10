import SwiftUI
import GhosttyKit

/// Renders a workspace's panes as an equal-split grid (rows × cols from
/// `workspace.layout`), placed by `PaneGridLayout`. Reading order: pane
/// index = row*cols + col.
///
/// THE IDENTITY LAW (this is what fixed ">4 panes corrupts the grid"): cells
/// are keyed by `pane.id` — one flat ForEach, one stable view per pane,
/// forever. The vendored `SurfaceRepresentable.updateOSView` only handles
/// size; it can NEVER swap one pane's NSView for another's. So cell identity
/// must follow the pane, not the grid slot. The old nested
/// ForEach(row)/ForEach(col) keyed cells by position — the first layout
/// boundary that changes `cols` with a second row present (4→5 panes:
/// 2×2→2×3, again at 9→10) remapped every row-1 slot to a different pane,
/// SwiftUI re-bound the cells, and surfaces ended up glued to the wrong
/// panes / reparented into two wrappers at once. With pane-keyed identity a
/// layout change only moves frames; surfaces never re-bind or reparent.
///
/// Zoom: the zoomed pane is placed over the full grid area; the hidden
/// siblings KEEP their grid frames (so their PTYs never resize/reflow) and
/// drop to opacity 0 + no hit testing.
struct TerminalGridView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let zoomedID = workspace.zoomedPaneID
        PaneGridLayout(layout: workspace.layout,
                       zoomedIndex: zoomedID.flatMap { id in
                           workspace.panes.firstIndex { $0.id == id }
                       }) {
            ForEach(workspace.panes) { pane in
                let hidden = zoomedID != nil && pane.id != zoomedID
                PaneCellView(pane: pane, workspace: workspace)
                    .opacity(hidden ? 0 : 1)
                    .allowsHitTesting(!hidden)
            }
        }
    }
}

/// Equal-cell grid placement (reading order, 2pt gutters), with an optional
/// zoom override: the zoomed child gets the full bounds, every other child
/// keeps its normal grid frame (invisible, but never resized — resizing a
/// hidden pane would reflow its PTY and garble TUIs mid-zoom).
private struct PaneGridLayout: Layout {
    let layout: GridLayout
    let zoomedIndex: Int?
    private let spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = CGFloat(max(1, layout.rows))
        let cols = CGFloat(max(1, layout.cols))
        let cellW = max(1, (bounds.width - spacing * (cols - 1)) / cols)
        let cellH = max(1, (bounds.height - spacing * (rows - 1)) / rows)
        for (i, subview) in subviews.enumerated() {
            let rect: CGRect
            if i == zoomedIndex {
                rect = bounds
            } else {
                let pos = layout.position(for: i)
                rect = CGRect(x: bounds.minX + CGFloat(pos.col) * (cellW + spacing),
                              y: bounds.minY + CGFloat(pos.row) * (cellH + spacing),
                              width: cellW, height: cellH)
            }
            subview.place(at: rect.origin, proposal: ProposedViewSize(rect.size))
        }
    }
}

/// One grid cell: the pane's surface (or a placeholder while spawning/suspended),
/// with an active-pane border. Tapping activates the pane without stealing the
/// click from the terminal (simultaneousGesture).
struct PaneCellView: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @ObservedObject var pane: Pane
    @ObservedObject var workspace: Workspace

    private var isActive: Bool { workspace.activePaneID == pane.id }
    // No border while zoomed — a full-window pane doesn't need "which pane
    // has focus" disambiguation, and an edge-to-edge accent ring reads as noise.
    private var showBorder: Bool {
        isActive && workspace.panes.count > 1 && workspace.zoomedPaneID == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            surfaceArea
            PaneNameBar(pane: pane, workspace: workspace)   // editable name strip at the bottom of the pane
        }
    }

    private var surfaceArea: some View {
        ZStack {
            if let surface = pane.surfaceView {
                Ghostty.SurfaceWrapper(surfaceView: surface)
            } else if pane.lifecycleState == .suspended {
                suspendedPlaceholder
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { roleBadge }
        .overlay {
            if showBorder {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(CHM.Color.accent.opacity(0.8), lineWidth: 2)
                    .allowsHitTesting(false)   // decorative — never eat a focus click
            }
        }
        // Dim inactive panes so the focused one is unmistakable. Driven by the
        // same activePaneID as the border (not SwiftUI @FocusState, which lagged
        // and left focus ambiguous); non-interactive so it never eats a click.
        .overlay {
            if !isActive && workspace.panes.count > 1 {
                Color.black.opacity(0.18).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // Live panes focus via the surface's own AppKit mouseDown (pixel-accurate;
        // see SurfaceView.mouseDown) — AppKit routes the click to the pane actually
        // under the cursor, so it can't be mis-attributed to a sibling the way the
        // SwiftUI per-cell DragGesture sometimes was ("clicked bottom-left, typed
        // into top-left"). Only surface-less cells (spawning / suspended placeholder)
        // still need this gesture, since there's no NSView to receive the click;
        // `including: .subviews` disables it once a surface exists. We keep the
        // modifier attached unconditionally (toggling only the mask) so the view's
        // SwiftUI identity stays stable.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in
                coordinator.focusPane(pane, in: workspace)
            },
            including: pane.surfaceView == nil ? .all : .subviews
        )
    }

    @ViewBuilder private var roleBadge: some View {
        if let role = pane.role, workspace.panes.count > 1 {
            Text(role.name)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((role.tint?.color ?? .secondary).opacity(0.16)))
                .foregroundStyle(role.tint?.color ?? .secondary)
                .padding(6)
                .allowsHitTesting(false)   // label only — let the click reach the surface

        }
    }

    private var suspendedPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz").font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            Text("Suspended — click to resume").font(CHM.Font.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
    }
}

/// A slim, click-to-edit name strip at the bottom of each pane, so a conversation
/// is always labeled and findable. Shows the user's custom name if set, else the
/// `/rename` / auto title; click to rename inline. Persisted per conversation id
/// (see ConversationLabelsManager) and shared with the Details "Name & note".
private struct PaneNameBar: View {
    @EnvironmentObject private var labels: ConversationLabelsManager
    @ObservedObject var pane: Pane
    @ObservedObject var workspace: Workspace
    @State private var hoveringZoom = false

    private var id: String { pane.conversation.id }
    private var isZoomed: Bool { workspace.zoomedPaneID == pane.id }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "tag")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            // Always an editable field — NOT a tap-to-edit mode. The Ghostty
            // surface is a greedy first responder; a mode that exited on any
            // focus loss would intermittently vanish before you could type
            // (autoreview P2). The placeholder shows the /rename / auto title
            // when there's no custom name. Bound straight to the store so it
            // stays in sync with the Details "Name" field.
            TextField(pane.conversation.previewText ?? "Name this conversation…",
                      text: Binding(get: { labels.label(for: id).name },
                                    set: { labels.setName($0, for: id) }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1)
            if workspace.panes.count > 1 {
                zoomButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CHM.Color.fillSubtle)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
        .help("Name this conversation")
    }

    /// Zoom toggle for this pane. While zoomed it's the only visible escape
    /// hatch besides ⇧⌘↩, so it stays on the bar (not hover-only).
    private var zoomButton: some View {
        Button {
            workspace.focus(pane.id)
            workspace.toggleZoom()
        } label: {
            Image(systemName: isZoomed
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hoveringZoom ? .secondary : .tertiary)
        }
        .buttonStyle(.plain)
        .onHover { hoveringZoom = $0 }
        .help(isZoomed ? "Unzoom — back to the grid (⇧⌘↩)" : "Zoom this pane (⇧⌘↩)")
    }
}
