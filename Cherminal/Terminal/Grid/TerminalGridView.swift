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
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { coordinator.focusPane(pane, in: workspace) })
    }

    @ViewBuilder private var roleBadge: some View {
        if let role = pane.role, workspace.panes.count > 1 {
            Text(role.name)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((role.tint?.color ?? .secondary).opacity(0.16)))
                .foregroundStyle(role.tint?.color ?? .secondary)
                .padding(6)
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
