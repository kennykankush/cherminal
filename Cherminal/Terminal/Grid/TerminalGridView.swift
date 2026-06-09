import SwiftUI
import GhosttyKit

/// Renders a workspace's panes as an equal-split grid (rows × cols from
/// `workspace.layout`). Explicit nested stacks (not LazyVGrid) so each cell gets
/// a real pixel frame — surfaces need their true size at spawn. Reading order:
/// pane index = row*cols + col.
struct TerminalGridView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let layout = workspace.layout
        VStack(spacing: 2) {
            ForEach(0..<max(1, layout.rows), id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<max(1, layout.cols), id: \.self) { col in
                        let index = row * layout.cols + col
                        if index < workspace.panes.count {
                            PaneCellView(pane: workspace.panes[index], workspace: workspace)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
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
    private var showBorder: Bool { isActive && workspace.panes.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            surfaceArea
            PaneNameBar(pane: pane)   // editable name strip at the bottom of the pane
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

    private var id: String { pane.conversation.id }

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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CHM.Color.fillSubtle)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
        .help("Name this conversation")
    }
}
