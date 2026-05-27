import AppKit
import SwiftUI
import GhosttyKit

/// Middle pane host. Bookmarks bar + tabs bar + active surface stacked
/// vertically. The TabsManager owns surface lifetimes so switching tabs
/// is a pure visibility swap, not a teardown.
struct TerminalPane: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @EnvironmentObject private var tabs: TabsManager

    var body: some View {
        VStack(spacing: 0) {
            BookmarksBar()
            TabsBar()
                .frame(height: 32)
            ZStack {
                BLV.Color.terminalBackground
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch ghostty.readiness {
        case .loading:
            ProgressView().controlSize(.small)
        case .error:
            errorPlaceholder
        case .ready:
            if tabs.tabs.isEmpty {
                emptyPlaceholder
            } else {
                MountedTerminalSurfaces(tabs: tabs.tabs, activeTabID: tabs.activeTabID)
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: BLV.Space.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: BLV.Space.xs) {
                Text("Standing in Belvedere")
                    .font(BLV.Font.bodyEmphasis)
                    .foregroundStyle(.secondary)
                Text("Pick a conversation from the left, or press ⌘T for a fresh terminal.")
                    .font(BLV.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(BLV.Space.xl)
    }

    private var errorPlaceholder: some View {
        VStack(spacing: BLV.Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("libghostty failed to initialize")
                .font(BLV.Font.bodyEmphasis)
                .foregroundStyle(.secondary)
            Text("Check ~/.config/ghostty/config for errors.")
                .font(BLV.Font.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// AppKit owns the mounted Ghostty surfaces so switching tabs does not
/// recreate SwiftUI representables or their NSScrollView / Metal view stack.
/// A tab switch only flips `isHidden` on already-mounted hosting views.
private struct MountedTerminalSurfaces: NSViewRepresentable {
    @EnvironmentObject private var ghostty: Ghostty.App

    let tabs: [TabsManager.Tab]
    let activeTabID: TabsManager.Tab.ID?

    func makeNSView(context: Context) -> MountedTerminalSurfacesView {
        MountedTerminalSurfacesView()
    }

    func updateNSView(_ nsView: MountedTerminalSurfacesView, context: Context) {
        nsView.update(tabs: tabs, activeTabID: activeTabID, ghostty: ghostty)
    }
}

private final class MountedTerminalSurfacesView: NSView {
    private struct Mount {
        let surfaceView: Ghostty.SurfaceView
        let hostView: NSHostingView<AnyView>
    }

    private var mounts: [TabsManager.Tab.ID: Mount] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [TabsManager.Tab],
                activeTabID: TabsManager.Tab.ID?,
                ghostty: Ghostty.App) {
        let liveIDs = Set(tabs.map(\.id))
        for (id, mount) in mounts where !liveIDs.contains(id) {
            mount.hostView.removeFromSuperview()
            mounts[id] = nil
        }

        for tab in tabs where mounts[tab.id] == nil {
            let root = AnyView(
                Ghostty.SurfaceWrapper(surfaceView: tab.surfaceView)
                    .environmentObject(ghostty)
            )
            let hostView = NSHostingView(rootView: root)
            hostView.frame = bounds
            hostView.autoresizingMask = [.width, .height]
            hostView.wantsLayer = true
            hostView.isHidden = tab.id != activeTabID
            addSubview(hostView)
            mounts[tab.id] = Mount(surfaceView: tab.surfaceView, hostView: hostView)
        }

        for tab in tabs {
            guard let mount = mounts[tab.id] else { continue }
            let isActive = tab.id == activeTabID
            mount.hostView.frame = bounds
            mount.hostView.isHidden = !isActive
            if isActive {
                mount.hostView.needsLayout = true
            }
        }
    }

    override func layout() {
        super.layout()
        for mount in mounts.values {
            mount.hostView.frame = bounds
            if !mount.hostView.isHidden {
                mount.hostView.needsLayout = true
            }
        }
    }
}
