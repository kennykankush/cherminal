import SwiftUI

/// The right-hand inspector, two-up: **Details** (the per-conversation
/// gauge/limits readout) and **Sessions** (a quick-look minimap of every open
/// tab's pane grid). A slim segmented header switches between them; the Sessions
/// segment carries a count + breathing dot when a pane needs you, so it stays
/// glanceable even from the Details tab.
struct InspectorPane: View {
    let conversation: Conversation?
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @AppStorage("cherminal.inspectorTab") private var tab: Tab = .context

    enum Tab: String { case context, sessions }

    /// Open panes whose agent is waiting on you right now — the glance count on
    /// the Sessions segment (matches what the minimap lights).
    private var awaitingCount: Int { coordinator.awaitingPaneIDs.count }
    /// Anything that wants you: a done pane, or a parked agent flagged attention.
    private var needsYou: Bool {
        !coordinator.awaitingPaneIDs.isEmpty
        || coordinator.detachedAgents.contains { $0.state == .attention }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .context:  ContextWatchPane(conversation: conversation)
            case .sessions: SessionsPane()
            }
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // @AppStorage writes round-trip through UserDefaults and drop out of a
        // withAnimation transaction (so the swap would just snap). Scope the
        // animation to the value instead — same workaround as SidebarView/ModeToggle.
        .animation(CHM.Motion.appear, value: tab)
    }

    private var header: some View {
        HStack(spacing: CHM.Space.xs) {
            segment("Details", .context, count: 0, alert: false)
            segment("Sessions", .sessions, count: awaitingCount, alert: needsYou)
        }
        .padding(.horizontal, CHM.Space.md)
        .padding(.vertical, CHM.Space.sm)
        .frame(maxWidth: .infinity)
    }

    private func segment(_ label: String, _ value: Tab, count: Int, alert: Bool) -> some View {
        let selected = tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 5) {
                Text(label).font(CHM.Font.captionEmphasis)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(alert ? CHM.Color.attention.opacity(0.22) : CHM.Color.fillSubtle))
                        .foregroundStyle(alert ? AnyShapeStyle(CHM.Color.attention) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, CHM.Space.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                    .fill(selected ? CHM.Color.activeFill : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// The Sessions tab: a **quick-look minimap** of every open tab's pane grid.
/// Each tab renders as a small grid mirroring its real layout; a cell pulses
/// blue when that pane's agent finished a turn and is waiting on you ("done"),
/// so you can watch many panes at once without switching tabs — click a cell to
/// jump straight to it. A compact "Parked" strip sits below for reattaching
/// agents you've closed (their dtach master is still alive).
struct SessionsPane: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator

    var body: some View {
        let tabs = coordinator.tabOverviews
        if tabs.isEmpty && coordinator.detachedAgents.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: CHM.Space.lg) {
                    if !tabs.isEmpty {
                        VStack(alignment: .leading, spacing: CHM.Space.md) {
                            ForEach(tabs) { tab in
                                TabMiniMap(tab: tab, isFrontmost: tab.id == coordinator.frontmostTabID)
                            }
                        }
                    }
                    if !coordinator.detachedAgents.isEmpty {
                        ParkedStrip()
                    }
                }
                .padding(CHM.Space.md)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: CHM.Icon.emptyState, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No open panes")
                .font(CHM.Font.bodyEmphasis).foregroundStyle(.secondary)
            Text("Open a conversation to see it light up here when it finishes.")
                .font(CHM.Font.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(CHM.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tab in the quick-look: its title + a mini grid that mirrors the tab's
/// pane layout. Observes the live `Workspace`, so it tracks splits and the
/// active pane in real time.
private struct TabMiniMap: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    let tab: TabWindowCoordinator.TabOverview
    let isFrontmost: Bool
    @ObservedObject private var workspace: Workspace

    init(tab: TabWindowCoordinator.TabOverview, isFrontmost: Bool) {
        self.tab = tab
        self.isFrontmost = isFrontmost
        self._workspace = ObservedObject(wrappedValue: tab.workspace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if isFrontmost {
                    Circle().fill(CHM.Color.accent).frame(width: 5, height: 5)
                        .help("Current tab")
                }
                Text(tab.title.isEmpty ? "Untitled" : tab.title)
                    .font(CHM.Font.captionEmphasis)
                    .foregroundStyle(isFrontmost ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if let p = workspace.activePane { coordinator.reveal(p) } }
            grid
        }
    }

    private var grid: some View {
        let layout = workspace.layout
        let rows = max(1, layout.rows)
        let cols = max(1, layout.cols)
        // Index mapping mirrors TerminalGridView exactly: pane = row*cols + col.
        return VStack(spacing: 3) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<cols, id: \.self) { col in
                        let index = row * cols + col
                        if index < workspace.panes.count {
                            MiniPaneCell(
                                pane: workspace.panes[index],
                                isActive: workspace.panes[index].id == workspace.activePaneID
                            )
                        } else {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.clear)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: rowHeight(rows))
            }
        }
    }

    /// Shrink rows as the grid grows so a 4×4 doesn't dominate the inspector.
    private func rowHeight(_ rows: Int) -> CGFloat {
        switch rows {
        case 1:  return 34
        case 2:  return 28
        case 3:  return 22
        default: return 18
        }
    }
}

/// One pane in the minimap. Pulses blue when its agent finished a turn and is
/// waiting on you ("done"); an accent ring marks the tab's active pane; a faint
/// accent fill = live and working; a bare outline = idle. Click to jump there.
private struct MiniPaneCell: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @ObservedObject var pane: Pane
    let isActive: Bool
    @State private var hovering = false

    private var isAwaiting: Bool { coordinator.awaitingPaneIDs.contains(pane.conversation.id) }
    private var isLive: Bool { coordinator.liveConversationIDs.contains(pane.conversation.id) }
    /// Agent running and mid-turn (live, not waiting on you) → show the loading bar.
    private var isWorking: Bool { isLive && !isAwaiting }

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(baseFill)
            // The "done" pulse, layered over the base so non-awaiting cells stay
            // solid. Conditionally inserted → its @State resets each awaiting
            // cycle, so the repeatForever breathe re-arms every time (same trick
            // as the sidebar status dot).
            .overlay { if isAwaiting { PulsingFill() } }
            // The "working" loading bar along the bottom edge while the agent is
            // mid-turn. Conditionally inserted so its sweep re-arms each time.
            .overlay(alignment: .bottom) { if isWorking { WorkingBar() } }
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(stroke, lineWidth: isActive ? 1.6 : 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { coordinator.reveal(pane) }
            .help(tooltip)
    }

    private var baseFill: SwiftUI.Color {
        if hovering { return CHM.Color.hoverFill }
        if isLive   { return CHM.Color.accent.opacity(0.14) }
        return CHM.Color.fillSubtle
    }

    private var stroke: SwiftUI.Color {
        if isActive   { return CHM.Color.accent.opacity(0.9) }
        if isAwaiting { return CHM.Color.attention }
        return CHM.Color.hairline
    }

    private var tooltip: String {
        let name = pane.conversation.agent.displayName
        let room = pane.conversation.roomName
        let state = isAwaiting ? "waiting for you" : (isWorking ? "working…" : "idle")
        return "\(name) · \(room) — \(state)\nClick to jump here"
    }
}

/// An indeterminate "working" sweep along a cell's bottom edge — shown while a
/// pane's agent is mid-turn (live but not awaiting you). Self-contained so the
/// sweep re-arms each time the cell enters the working state.
private struct WorkingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        if reduceMotion {
            // No motion: a steady faint bar still reads as "working".
            Capsule().fill(CHM.Color.accent.opacity(0.5))
                .frame(height: 2.5)
                .padding(.horizontal, 2)
        } else {
            GeometryReader { geo in
                let w = geo.size.width
                let seg = max(10, w * 0.4)
                Capsule()
                    .fill(CHM.Color.accent)
                    .frame(width: seg, height: 2.5)
                    .position(x: animate ? w - seg / 2 : seg / 2, y: 1.5)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: animate)
            }
            .frame(height: 3)
            .padding(.horizontal, 2)
            .onAppear { animate = true }
        }
    }
}

/// The breathing blue fill for a "done" pane. Self-contained so its animation
/// state resets cleanly each time it appears (see MiniPaneCell).
private struct PulsingFill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(CHM.Color.attention)
            .opacity(on ? 0.9 : 0.4)
            .animation(reduceMotion ? nil : CHM.Motion.breathe, value: on)
            .onAppear { on = true }
    }
}

/// Compact strip of parked (detached) agents — panes you closed whose `dtach`
/// master is still alive off-screen. Click a chip to reattach; right-click for
/// reattach-as-tab / kill.
private struct ParkedStrip: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: CHM.Space.xs)]

    var body: some View {
        VStack(alignment: .leading, spacing: CHM.Space.sm) {
            Text("Parked")
                .font(CHM.Font.eyebrow)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            LazyVGrid(columns: columns, alignment: .leading, spacing: CHM.Space.xs) {
                ForEach(coordinator.detachedAgents) { agent in
                    ParkedChip(agent: agent)
                }
            }
        }
    }
}

private struct ParkedChip: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    let agent: DetachedAgent
    @State private var hovering = false

    var body: some View {
        Button { coordinator.reattach(agent) } label: {
            HStack(spacing: 5) {
                AgentBadge(agent: agent.conversation.agent, size: 14)
                Text(title)
                    .font(CHM.Font.caption)
                    .foregroundStyle(agent.state == .dead ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 2)
                dot
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule()
                    .fill(hovering ? CHM.Color.hoverFill : CHM.Color.fillSubtle)
                    .overlay(
                        Capsule().strokeBorder(tint.opacity(agent.state == .dead ? 0.25 : 0.5), lineWidth: 1)
                    )
            )
            .opacity(agent.state == .dead ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
        .contextMenu {
            Button("Reattach Here") { coordinator.reattach(agent) }
            Button("Reattach as Tab") { coordinator.reattachAsTab(agent) }
            Divider()
            Button("Kill", role: .destructive) { coordinator.killDetached(agent) }
        }
    }

    @ViewBuilder private var dot: some View {
        switch agent.state {
        case .attention: Circle().fill(CHM.Color.attention).frame(width: 6, height: 6)
        case .working:   Circle().fill(CHM.Color.accent).frame(width: 5, height: 5)
        case .dead:      Circle().fill(CHM.Color.alert.opacity(0.55)).frame(width: 5, height: 5)
        }
    }

    private var tint: SwiftUI.Color {
        switch agent.state {
        case .attention: return CHM.Color.attention
        case .working:   return CHM.Color.accent
        case .dead:      return CHM.Color.alert
        }
    }

    private var title: String {
        let room = agent.conversation.roomName.trimmingCharacters(in: .whitespaces)
        return room.isEmpty ? agent.conversation.agent.displayName : room
    }

    private var tooltip: String {
        let name = agent.conversation.agent.displayName
        let room = agent.conversation.roomName
        let stateWord: String
        switch agent.state {
        case .attention: stateWord = "waiting for you"
        case .working:   stateWord = "working…"
        case .dead:      stateWord = "ended"
        }
        return "\(name) · \(room) — \(stateWord)\n"
            + (agent.state == .dead ? "Click to resume · right-click to clear" : "Click to reattach")
    }
}
