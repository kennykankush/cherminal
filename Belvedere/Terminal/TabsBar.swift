import AppKit
import SwiftUI

/// SwiftUI wrapper around the AppKit-rendered tab strip. Hosting the
/// strip in real AppKit (CALayer-backed cells, NSScrollView, NSTrackingArea
/// for hover) gives us the same compositor pipeline Ghostty uses for its
/// title-bar tabs — no SwiftUI re-render cost on hover / click.
struct TabsBar: NSViewRepresentable {
    @EnvironmentObject private var tabs: TabsManager
    @EnvironmentObject private var ghostty: Ghostty.App

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TabBarContainerView {
        let view = TabBarContainerView()
        view.onActivate = { [weak tabs] id in tabs?.activate(id) }
        view.onClose = { [weak tabs] id in tabs?.close(id) }
        view.onNewTab = { [weak tabs, weak ghostty] in
            guard let tabs, let app = ghostty?.app else { return }
            tabs.openFreshShell(in: app, configBuilder: TerminalCommand.surfaceConfig(for:))
        }
        view.tabs = modelArray()
        return view
    }

    func updateNSView(_ nsView: TabBarContainerView, context: Context) {
        nsView.tabs = modelArray()
        // Keep references fresh — environment objects can be reassigned
        // when the parent updates.
        nsView.onActivate = { [weak tabs] id in tabs?.activate(id) }
        nsView.onClose = { [weak tabs] id in tabs?.close(id) }
        nsView.onNewTab = { [weak tabs, weak ghostty] in
            guard let tabs, let app = ghostty?.app else { return }
            tabs.openFreshShell(in: app, configBuilder: TerminalCommand.surfaceConfig(for:))
        }
    }

    private func modelArray() -> [TabCellView.Model] {
        let activeID = tabs.activeTabID
        return tabs.tabs.map { tab in
            TabCellView.Model(
                id: tab.id,
                title: tab.conversation.roomName,
                isActive: tab.id == activeID
            )
        }
    }

    final class Coordinator {}
}
