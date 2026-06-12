import SwiftUI

/// The right-hand inspector, two-up: **Details** (the per-conversation
/// gauge/limits readout) and **Sessions** (a quick-look minimap of every open
/// tab's pane grid). A slim segmented header switches between them; the Sessions
/// segment carries a count + breathing dot when a pane needs you, so it stays
/// glanceable even from the Details tab.
struct InspectorPane: View {
    /// The active pane — observed one level down (ObservedPaneDetails) so an
    /// identity adoption or a pendingAgent flip re-renders the Details tab
    /// directly, without waiting for a coordinator-level republish.
    let pane: Pane?
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
            case .context:
                if let pane {
                    ObservedPaneDetails(pane: pane)
                } else {
                    ContextWatchPane(conversation: nil, pendingAgent: nil)
                }
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

/// Observation shim: holds the @ObservedObject so Pane's @Published identity
/// (adoption flips) and pendingAgent (new-chat detection) drive the Details
/// tab live.
private struct ObservedPaneDetails: View {
    @ObservedObject var pane: Pane

    var body: some View {
        ContextWatchPane(conversation: pane.conversation, pendingAgent: pane.pendingAgent)
    }
}

/// The Sessions tab: a **quick-look minimap** of every open tab's pane grid,
/// in the user's visible tab order. Each tab renders as a small grid mirroring
/// its real layout; a cell glows blue when that pane's agent finished a turn
/// and is waiting on you ("done"), so you can watch many panes at once without
/// switching tabs — click a cell to jump straight to it. A compact "Parked"
/// strip sits below for reattaching agents you've closed (their dtach master
/// is still alive).
struct SessionsPane: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator

    var body: some View {
        let tabs = coordinator.tabOverviews
        if tabs.isEmpty && coordinator.detachedAgents.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: CHM.Space.xl) {
                    if !tabs.isEmpty {
                        VStack(alignment: .leading, spacing: CHM.Space.md) {
                            sectionHeader("Open tabs", count: tabs.count)
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                TabMiniMap(tab: tab,
                                           index: index + 1,
                                           isFrontmost: tab.id == coordinator.frontmostTabID)
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

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: CHM.Space.xs) {
            Text(title)
                .font(CHM.Font.eyebrow)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Text("\(count)")
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer(minLength: 0)
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

/// One tab in the quick-look: an index numeral (matches ⌘1-9 in visible
/// order) + title row, and a mini grid that mirrors the tab's pane layout.
/// Observes the live `Workspace`, so it tracks splits, renames, and the
/// active pane in real time. Right-click the row for tab actions.
private struct TabMiniMap: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    let tab: TabWindowCoordinator.TabOverview
    let index: Int
    let isFrontmost: Bool
    @ObservedObject private var workspace: Workspace
    @State private var hoveringRow = false

    init(tab: TabWindowCoordinator.TabOverview, index: Int, isFrontmost: Bool) {
        self.tab = tab
        self.index = index
        self.isFrontmost = isFrontmost
        self._workspace = ObservedObject(wrappedValue: tab.workspace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The tab's position in visible order — the same number ⌘n
                // jumps to, so the minimap teaches the shortcut for free.
                Text(index <= 9 ? "⌘\(index)" : "\(index)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isFrontmost ? AnyShapeStyle(CHM.Color.accent) : AnyShapeStyle(.tertiary))
                // The user's tab rename wins (observed live off the workspace);
                // else the snapshot title (the room) from when the tab opened.
                Text(workspace.name ?? (tab.title.isEmpty ? "Untitled" : tab.title))
                    .font(CHM.Font.captionEmphasis)
                    .foregroundStyle(isFrontmost ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: CHM.Radius.chip, style: .continuous)
                    .fill(isFrontmost ? CHM.Color.activeFill : (hoveringRow ? CHM.Color.hoverFill : .clear))
            )
            .contentShape(Rectangle())
            .onHover { hoveringRow = $0 }
            .onTapGesture { if let p = workspace.activePane { coordinator.reveal(p) } }
            .contextMenu {
                Button("Jump Here") { if let p = workspace.activePane { coordinator.reveal(p) } }
                Button("Rename Tab…") { coordinator.beginRename(tabID: tab.id) }
                Divider()
                Button("Close Tab", role: .destructive) { coordinator.closeTab(tabID: tab.id) }
            }
            .help(isFrontmost ? "Current tab" : "Click to jump to this tab")
            grid
                .padding(.horizontal, 6)
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

/// One pane in the minimap. A calm blue glow when its agent finished a turn
/// and is waiting on you ("done"); an accent ring marks the tab's active pane;
/// a faint accent fill + thin sweep = live and working; a bare outline = idle.
/// Click to jump there; right-click for pane actions. State changes crossfade
/// (200ms) instead of popping.
private struct MiniPaneCell: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @ObservedObject var pane: Pane
    let isActive: Bool
    @State private var hovering = false

    /// The cell's resolved state — one value, so the crossfade animation is
    /// scoped to genuine state changes and nothing else.
    private enum CellState: Equatable { case idle, working, awaiting, bursting }
    private var state: CellState {
        if coordinator.burstingAgents.contains(pane.conversation.agent) { return .bursting }
        let live = coordinator.liveConversationIDs.contains(pane.conversation.id)
        if coordinator.awaitingPaneIDs.contains(pane.conversation.id) { return .awaiting }
        return live ? .working : .idle
    }

    var body: some View {
        let state = self.state
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            // Burst overrides every other state — it's the loudest signal.
            .fill(state == .bursting ? CHM.Color.alert.opacity(0.92) : baseFill(state))
            .overlay {
                if state == .bursting {
                    Text("BURST")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.horizontal, 2)
                } else if state == .awaiting {
                    DoneGlow()
                }
            }
            // The thin "working" sweep along the bottom edge while mid-turn.
            .overlay(alignment: .bottom) { if state == .working { WorkingSweep() } }
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(stroke(state),
                                  lineWidth: (state == .bursting || isActive) ? 1.6 : 1)
            )
            // Crossfade between states — without this, working↔done flips pop
            // and read as glitches. Value-scoped: hover/renders never animate.
            .animation(.easeOut(duration: 0.2), value: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { coordinator.reveal(pane) }
            .contextMenu {
                Button("Jump Here") { coordinator.reveal(pane) }
                Button("Zoom Pane") { coordinator.toggleZoom(pane) }
                Divider()
                Button("Close Pane (park)", role: .destructive) { coordinator.close(pane) }
                Button("Kill Pane", role: .destructive) { coordinator.kill(pane) }
            }
            .help(tooltip(state))
    }

    private func baseFill(_ state: CellState) -> SwiftUI.Color {
        if hovering { return CHM.Color.hoverFill }
        if state == .working { return CHM.Color.accent.opacity(0.12) }
        return CHM.Color.fillSubtle
    }

    private func stroke(_ state: CellState) -> SwiftUI.Color {
        if state == .bursting { return CHM.Color.alert }
        if isActive           { return CHM.Color.accent.opacity(0.9) }
        if state == .awaiting { return CHM.Color.attention }
        return CHM.Color.hairline
    }

    private func tooltip(_ state: CellState) -> String {
        let name = pane.conversation.agent.displayName
        let room = pane.conversation.roomName
        let word: String
        switch state {
        case .bursting: word = "usage limit reached (burst)"
        case .awaiting: word = "waiting for you"
        case .working:  word = "working…"
        case .idle:     word = "idle"
        }
        return "\(name) · \(room) — \(word)\nClick to jump here"
    }
}

/// The "working" indicator: a thin segment sweeping ONE direction along the
/// cell's bottom edge, linear, wall-clock-driven — steady and unhurried, like
/// a quiet progress shimmer. (The old version ping-ponged with autoreverse and
/// restarted on every re-render — exactly the back-and-forth glitch.)
private struct WorkingSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // No motion: a steady faint bar still reads as "working".
            Capsule().fill(CHM.Color.accent.opacity(0.5))
                .frame(height: 2)
                .padding(.horizontal, 2)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                GeometryReader { geo in
                    let w = geo.size.width
                    let seg = max(12, w * 0.38)
                    // Travel from fully off-left to fully off-right, then wrap.
                    let x = -seg + CHM.Phase.ramp(context.date, period: 1.8) * (w + seg)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [CHM.Color.accent.opacity(0),
                                     CHM.Color.accent.opacity(0.85),
                                     CHM.Color.accent.opacity(0)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: seg, height: 2)
                        .offset(x: x)
                }
                .clipped()
            }
            .frame(height: 2)
            .padding(.horizontal, 2)
            .padding(.bottom, 1.5)
        }
    }
}

/// The "done / your turn" fill: a slow luminance breathe of the attention
/// blue — no movement, wall-clock-driven so it can never jump or desync.
private struct DoneGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(CHM.Color.attention)
                .opacity(0.65)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CHM.Color.attention)
                    .opacity(0.45 + 0.35 * CHM.Phase.breathe(context.date, period: 2.8))
            }
        }
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
