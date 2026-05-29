import SwiftUI
import AppKit

/// The right-hand inspector: a single calm, per-conversation readout. The
/// context-window gauge is the centerpiece (visible the instant the inspector
/// opens — no mode-switching). Pinning is a glyph in the header; the pinned
/// *list* lives in the sidebar; saved groups live in the Window menu; dev-server
/// ports collapse into an ambient footer that shows nothing when there are none.
struct ContextWatchPane: View {
    let conversation: Conversation?

    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var pins: PinsManager
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @EnvironmentObject private var ports: PortsManager

    @State private var usage: ConversationUsage?
    @State private var showTokenDetails = false
    @State private var portsExpanded = false
    /// Balanced start/stop on the shared PortsManager (poll only while a pane
    /// is on screen), so its viewer refcount can't drift.
    @State private var portViewing = false

    var body: some View {
        VStack(spacing: 0) {
            if let convo = conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: CHM.Space.lg) {
                        headerRow(convo)
                        if let usage {
                            gaugeSection(usage)
                            if !usage.rateWindows.isEmpty { limitsSection(usage) }
                            tokensSection(usage)
                        }
                        sessionSection(convo)
                    }
                    .padding(CHM.Space.xl)
                }
                portsFooter
            } else {
                emptyState
            }
        }
        .onAppear { setPortViewing(true) }
        .onDisappear { setPortViewing(false) }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // Live-refresh usage for the active conversation. Claude folds in
        // append-only deltas via the accumulator (which now survives for the
        // conversation's lifetime — no tab toggle tears it down); Codex re-reads
        // its tail. Fully local — reads the session JSONL only.
        .task(id: conversation?.id) {
            usage = nil
            showTokenDetails = false   // per-conversation; don't carry across switches
            guard let convo = conversation,
                  convo.agent == .claudeCode || convo.agent == .codex else { return }
            let file = convo.sessionFile
            let agent = convo.agent
            let accumulator = ClaudeUsageAccumulator()
            while !Task.isCancelled {
                let parsed = await Task.detached(priority: .utility) {
                    agent == .codex
                        ? ConversationUsageParser.parseCodex(sessionFile: file)
                        : accumulator.ingest(file: file)
                }.value
                if Task.isCancelled { break }
                if let parsed { usage = parsed }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    // MARK: - Header (identity + pin)

    private func headerRow(_ convo: Conversation) -> some View {
        HStack(alignment: .top, spacing: CHM.Space.sm) {
            AgentBadge(agent: convo.agent, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(convo.agent.displayName)
                    .font(CHM.Font.bodyEmphasis)
                Text(convo.previewText ?? "Untitled conversation")
                    .font(CHM.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: CHM.Space.xs)
            Button {
                pins.toggle(convo.id)
            } label: {
                Image(systemName: pins.isPinned(convo.id) ? "pin.fill" : "pin")
                    .font(CHM.Font.captionEmphasis)
                    .foregroundStyle(pins.isPinned(convo.id) ? AnyShapeStyle(CHM.Color.accent) : AnyShapeStyle(.tertiary))
                    .rotationEffect(.degrees(pins.isPinned(convo.id) ? 0 : 0))
            }
            .buttonStyle(.plain)
            .help(pins.isPinned(convo.id) ? "Unpin this conversation" : "Pin this conversation")
        }
        .padding(.top, 24)   // clear the traffic-light overlay (hiddenTitleBar)
    }

    // MARK: - Gauge (the centerpiece)

    private func gaugeSection(_ u: ConversationUsage) -> some View {
        section("Context window") {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: CHM.Space.xs) {
                    Text("\(Int(u.contextUsedPercent))%")
                        .font(CHM.Font.metric)
                        .foregroundStyle(usageColor(u.contextUsedPercent))
                        .monospacedDigit()
                        .animation(CHM.Motion.appear, value: u.contextUsedPercent)
                    Text("full")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let model = u.modelDisplayName {
                        Text(model)
                            .font(CHM.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                usageBar(percent: u.contextUsedPercent)
                HStack {
                    Text("\(formatTokens(u.contextUsedTokens)) / \(formatTokens(u.contextWindowTokens))")
                    Spacer()
                    Text("\(formatTokens(u.contextRemainingTokens)) left")
                }
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
    }

    private func limitsSection(_ u: ConversationUsage) -> some View {
        section("Usage limits") {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                ForEach(u.rateWindows) { w in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(w.label).font(CHM.Font.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(w.usedPercent))%")
                                .font(CHM.Font.captionEmphasis)
                                .foregroundStyle(usageColor(w.usedPercent))
                                .monospacedDigit()
                        }
                        usageBar(percent: w.usedPercent)
                        if let resets = w.resetsAt {
                            Text("resets \(resets.formatted(.relative(presentation: .named)))")
                                .font(CHM.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    /// Calm ramp: neutral until 75%, the app's clay accent 75–90%, a muted
    /// (desaturated) red only at 90%+. One color on screen; soft fades.
    private func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<75: return .secondary
        case ..<90: return CHM.Color.accent
        default:    return CHM.Color.alert
        }
    }

    private func usageBar(percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CHM.Color.hairline)
                Capsule()
                    .fill(usageColor(percent))
                    .frame(width: max(3, geo.size.width * CGFloat(percent / 100)))
                    .animation(CHM.Motion.appear, value: percent)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Tokens (one line + details)

    private func tokensSection(_ u: ConversationUsage) -> some View {
        section("Tokens this session") {
            VStack(alignment: .leading, spacing: CHM.Space.xs) {
                Text("In \(formatTokens(u.totalInputTokens)) · Out \(formatTokens(u.totalOutputTokens)) · \(Int(u.cacheHitPercent))% cached")
                    .font(CHM.Font.monoSmall)
                    .foregroundStyle(.tertiary)
                DisclosureGroup(isExpanded: $showTokenDetails) {
                    VStack(spacing: CHM.Space.xs) {
                        tokenRow("Input", u.totalInputTokens)
                        tokenRow("Output", u.totalOutputTokens)
                        tokenRow("Cache read", u.cacheReadTokens)
                        tokenRow("Cache write", u.cacheCreateTokens)
                    }
                    .padding(.top, CHM.Space.xs)
                } label: {
                    Text("Details").font(CHM.Font.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tokenRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).font(CHM.Font.caption).foregroundStyle(.secondary)
            Spacer()
            Text(formatTokens(value)).font(CHM.Font.monoSmall).foregroundStyle(.primary)
        }
    }

    // MARK: - Session (identity + room, merged)

    private func sessionSection(_ convo: Conversation) -> some View {
        section("Session") {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                // Only an exact, trustworthy count (Claude); hidden otherwise.
                if let count = usage?.messageCount {
                    metaRow("Messages", "\(count)")
                }
                if let first = convo.firstMessageAt {
                    metaRow("Started", first.formatted(date: .abbreviated, time: .shortened))
                }
                metaRow("Last activity", convo.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                metaRow("Folder", convo.roomName)
                metaRow("Path", convo.roomPath.path, mono: true)
            }
        }
    }

    private func metaRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CHM.Space.sm) {
            Text(key)
                .font(CHM.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(mono ? CHM.Font.monoSmall : CHM.Font.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(mono ? 2 : 1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Ports footer (ambient)

    @ViewBuilder
    private var portsFooter: some View {
        if !ports.ports.isEmpty {
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                Button {
                    withAnimation(CHM.Motion.appear) { portsExpanded.toggle() }
                } label: {
                    HStack(spacing: CHM.Space.xs) {
                        Image(systemName: "network").font(CHM.Font.caption).foregroundStyle(.tertiary)
                        Text("\(ports.ports.count) dev server\(ports.ports.count == 1 ? "" : "s")")
                            .font(CHM.Font.captionEmphasis)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: portsExpanded ? "chevron.down" : "chevron.up")
                            .font(CHM.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, CHM.Space.lg)
                    .padding(.vertical, CHM.Space.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if portsExpanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: CHM.Space.sm) {
                            ForEach(DevPort.Category.allCases, id: \.self) { category in
                                let rows = ports.ports.filter { $0.category == category }
                                if !rows.isEmpty {
                                    VStack(alignment: .leading, spacing: CHM.Space.xs) {
                                        Text(category.rawValue)
                                            .font(CHM.Font.eyebrow)
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)
                                            .tracking(0.6)
                                        ForEach(rows) { p in
                                            PortRow(port: p, chatName: chatName(for: p))
                                                .onTapGesture { openInBrowser(p.port) }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, CHM.Space.lg)
                        .padding(.bottom, CHM.Space.md)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private func chatName(for p: DevPort) -> String? {
        if let cid = p.conversationID, let convo = registry.conversation(id: cid) {
            return convo.previewText ?? convo.roomName
        }
        return p.roomName
    }

    private func setPortViewing(_ on: Bool) {
        guard on != portViewing else { return }
        portViewing = on
        if on { ports.start() } else { ports.stop() }
    }

    private func openInBrowser(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Chrome

    private var emptyState: some View {
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: CHM.Icon.emptyState, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing selected")
                .font(CHM.Font.bodyEmphasis)
            Text("Open a conversation to see its context window, tokens, and session.")
                .font(CHM.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CHM.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, CHM.Space.xxl)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CHM.Space.sm) {
            Text(title)
                .font(CHM.Font.eyebrow)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// One dev-server port row: port number, process, attributed chat/room, and
/// an open-in-browser affordance.
private struct PortRow: View {
    let port: DevPort
    let chatName: String?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: CHM.Space.sm) {
            Text(":\(port.port)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(port.command)
                    .font(CHM.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let chatName {
                    Text(chatName)
                        .font(CHM.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: CHM.Space.xs)
            Image(systemName: hovering ? "arrow.up.forward.app.fill" : "arrow.up.forward.app")
                .font(CHM.Font.caption)
                .foregroundStyle(hovering ? AnyShapeStyle(CHM.Color.accent) : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, CHM.Space.sm)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: CHM.Radius.chip)
            .fill(hovering ? CHM.Color.hoverFill : CHM.Color.fillSubtle))
        .onHover { hovering = $0 }
        .help("Open http://localhost:\(port.port)")
    }
}
