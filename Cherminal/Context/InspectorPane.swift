import SwiftUI

/// The right-hand inspector, now two-up: **Context** (the per-conversation
/// gauge/limits readout) and **Sessions** (detached agents kept alive under
/// their `dtach` masters — formerly the edge rail). A slim segmented header
/// switches between them; the Sessions segment carries a count and a breathing
/// dot when a parked agent needs you, so it's glanceable even from the Context
/// tab.
struct InspectorPane: View {
    let conversation: Conversation?
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @AppStorage("cherminal.inspectorTab") private var tab: Tab = .context
    @State private var spawnedAgents: [SpawnedAgent] = []

    enum Tab: String { case context, sessions }

    private var parkedCount: Int { coordinator.detachedAgents.count }
    private var needsYou: Bool { coordinator.detachedAgents.contains { $0.state == .attention } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .context:  ContextWatchPane(conversation: conversation)
            case .sessions: SessionsPane(spawnedAgents: spawnedAgents)
            }
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // @AppStorage writes round-trip through UserDefaults and drop out of a
        // withAnimation transaction (so the swap would just snap). Scope the
        // animation to the value instead — same workaround as SidebarView/ModeToggle.
        .animation(CHM.Motion.appear, value: tab)
        // Scan the active Claude session's spawned sub-agents here (always-present
        // root, fires for both tabs) and hand them to SessionsPane. Hosting the
        // scan on the conditionally-empty pets view never fired its .task.
        .task(id: conversation?.id) {
            spawnedAgents = []
            guard let convo = conversation, convo.agent == .claudeCode else { return }
            while !Task.isCancelled {
                let scanned = await Task.detached(priority: .utility) {
                    SpawnedAgentScanner.scan(for: convo)
                }.value
                if Task.isCancelled { break }
                if scanned != spawnedAgents { spawnedAgents = scanned }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var header: some View {
        HStack(spacing: CHM.Space.xs) {
            segment("Details", .context, count: 0, alert: false)
            segment("Sessions", .sessions, count: parkedCount, alert: needsYou)
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

/// The Sessions tab: parked agents as a "minefield" — a wrapping grid of small
/// tiles, each lit by state (breathing blue = needs you, amber = working, red =
/// ended). Click a tile to reattach; right-click for more. Calm empty state
/// when nothing's parked.
struct SessionsPane: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    /// Sub-agents the active Claude session has spawned (scanned by InspectorPane).
    var spawnedAgents: [SpawnedAgent] = []

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: CHM.Space.sm)]

    var body: some View {
        if coordinator.detachedAgents.isEmpty && spawnedAgents.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: CHM.Space.lg) {
                    if !coordinator.detachedAgents.isEmpty {
                        LazyVGrid(columns: columns, spacing: CHM.Space.sm) {
                            ForEach(coordinator.detachedAgents) { agent in
                                MineCell(agent: agent)
                            }
                        }
                    }
                    // The spawned-agent Clawd field, below the parked sessions.
                    if !spawnedAgents.isEmpty {
                        ClawdPetsView(agents: spawnedAgents)
                    }
                }
                .padding(CHM.Space.md)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: CHM.Icon.emptyState, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No parked sessions")
                .font(CHM.Font.bodyEmphasis).foregroundStyle(.secondary)
            Text("Close an agent (⌘⇧W) to keep it running here in the background.")
                .font(CHM.Font.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(CHM.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tile in the minefield: a small card with the agent's logo (Claude /
/// Codex), the room title, and a status dot. Click reattaches; right-click for
/// reattach-as-tab / kill. Tooltip carries the agent + state + preview.
private struct MineCell: View {
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    let agent: DetachedAgent
    @State private var breathing = false
    @State private var hovering = false

    var body: some View {
        Button {
            coordinator.reattach(agent)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AgentBadge(agent: agent.conversation.agent, size: 18)
                    Text(agent.conversation.agent.displayName)
                        .font(CHM.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    statusDot
                }
                Text(title)
                    .font(CHM.Font.captionEmphasis)
                    .foregroundStyle(agent.state == .dead ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(CHM.Space.sm)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                    .fill(hovering ? CHM.Color.hoverFill : CHM.Color.fillSubtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                            .strokeBorder(tint.opacity(agent.state == .dead ? 0.22 : 0.45), lineWidth: 1)
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

    @ViewBuilder private var statusDot: some View {
        switch agent.state {
        case .attention:
            ZStack {
                Circle().fill(CHM.Color.attentionHalo).frame(width: 12, height: 12).blur(radius: 2.5)
                Circle().fill(CHM.Color.attention).frame(width: 6, height: 6)
            }
            .opacity(breathing ? 1.0 : 0.8)
            .animation(CHM.Motion.breathe, value: breathing)
            .onAppear { breathing = true }
        case .working:
            Circle().fill(CHM.Color.accent)
                .frame(width: 6, height: 6)
                .opacity(breathing ? 1.0 : 0.5)
                .animation(CHM.Motion.breathe, value: breathing)
                .onAppear { breathing = true }
        case .dead:
            Circle().fill(CHM.Color.alert.opacity(0.55)).frame(width: 5, height: 5)
        }
    }

    private var tint: SwiftUI.Color {
        switch agent.state {
        case .attention: return CHM.Color.attention
        case .working:   return CHM.Color.accent
        case .dead:      return CHM.Color.alert
        }
    }

    /// The room is the clearest label for "what is this". Fall back to a preview
    /// snippet, then the agent name, so a tile is never blank.
    private var title: String {
        let room = agent.conversation.roomName.trimmingCharacters(in: .whitespaces)
        if !room.isEmpty { return room }
        if let p = agent.conversation.previewText?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return String(p.prefix(48))
        }
        return agent.conversation.agent.displayName
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
        var t = "\(name) · \(room) — \(stateWord)"
        if let p = agent.conversation.previewText?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            t += "\n\(String(p.prefix(120)))"
        }
        t += agent.state == .dead ? "\nClick to resume · right-click to clear" : "\nClick to reattach"
        return t
    }
}
