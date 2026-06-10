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
    @EnvironmentObject private var labels: ConversationLabelsManager

    @State private var usage: ConversationUsage?
    @State private var pulse: SessionPulse.Pulse?
    @State private var procFacts: TabWindowCoordinator.ProcessFacts?
    @State private var showTokenDetails = false
    @State private var portsExpanded = false
    @State private var gitStatus: GitStatus?
    @State private var showGitDetails = false
    @State private var nameDraft = ""
    @State private var noteDraft = ""
    /// Live usage accumulator per conversation id, held OUTSIDE the poll task
    /// so a visibility restart (tab switch) resumes folding deltas instead of
    /// re-ingesting the whole session file.
    @State private var accumulators: [String: ClaudeUsageAccumulator] = [:]
    /// Whether this window is actually on screen. Every native tab hosts its
    /// own inspector, and these poll loops used to run for EVERY open tab —
    /// the per-tab multiplication was the heaviest standing cost at high tab
    /// counts. `.inactive` = our window is hidden (a deselected native tab);
    /// the task ids below include this so a hidden tab's loops simply end and
    /// restart (with an immediate refresh) when the tab is selected again.
    @Environment(\.controlActiveState) private var controlActiveState
    private var windowVisible: Bool { controlActiveState != .inactive }

    var body: some View {
        VStack(spacing: 0) {
            if let convo = conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: CHM.Space.lg) {
                        headerRow(convo)
                        // Loud red burst banner when THIS conversation's agent has
                        // hit its account usage limit (the limit is account-wide).
                        if coordinator.burstingAgents.contains(convo.agent) {
                            BurstBanner(agents: [convo.agent])
                        }
                        labelSection(convo)
                        // The conversation itself, before the machine vitals:
                        // what the agent is working through, and the last
                        // exchange — the "catch up in two seconds" glance.
                        if let pulse, !pulse.todos.isEmpty { planSection(pulse) }
                        if let pulse, pulse.lastUserText != nil || pulse.lastAssistantText != nil {
                            latestSection(pulse, convo)
                        }
                        if let usage {
                            // 5H / Weekly account windows sit ABOVE the context
                            // window — glanceable rate-limit headroom first.
                            if !usage.rateWindows.isEmpty { limitsSection(usage) }
                            gaugeSection(usage)
                            tokensSection(usage)
                        }
                        if let gitStatus { gitSection(gitStatus) }
                        processSection(convo)
                        sessionSection(convo)
                    }
                    .padding(CHM.Space.xl)
                }
                portsFooter
            } else {
                emptyState
            }
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // Seed the name/note drafts from the store whenever the conversation
        // changes (and on first appear). Edits commit back via onChange below.
        .onChange(of: conversation?.id, initial: true) {
            let l = conversation.map { labels.label(for: $0.id) } ?? .init()
            nameDraft = l.name
            noteDraft = l.note
        }
        // Reset per-conversation readouts when the SELECTION changes (not on a
        // visibility flip, which would blank the gauge on every tab switch).
        .onChange(of: conversation?.id) {
            usage = nil
            pulse = nil
            procFacts = nil
            showTokenDetails = false
            accumulators = [:]
        }
        // Live-refresh usage for the active conversation. Claude folds in
        // append-only deltas via the accumulator (held in @State so a tab
        // switch resumes instead of re-ingesting); Codex re-reads its tail.
        // Fully local — reads the session JSONL only. The loop exists ONLY
        // while this window is visible (id includes windowVisible): hidden
        // tabs cost nothing, and selecting a tab restarts the loop with an
        // immediate refresh.
        .task(id: "\(conversation?.id ?? "none")-\(windowVisible)") {
            guard windowVisible,
                  let convo = conversation,
                  convo.agent == .claudeCode || convo.agent == .codex else { return }
            let agent = convo.agent
            let accumulator: ClaudeUsageAccumulator
            if let existing = accumulators[convo.id] {
                accumulator = existing
            } else {
                accumulator = ClaudeUsageAccumulator()
                accumulators = [convo.id: accumulator]   // keep only the active one
            }
            while !Task.isCancelled {
                // Also pause while the whole app is backgrounded — nothing on
                // screen needs the file parse + usage API call.
                if NSApp.isActive {
                    // Codex `resume` forks a new rollout file, so read the live one
                    // the agent is actually writing (else the gauge/tokens/limits go
                    // stale and the Usage limits section vanishes). Claude appends to
                    // its tracked file, so liveFile is nil there — no change.
                    let file = (agent == .codex ? coordinator.liveFile(for: convo.id) : nil) ?? convo.sessionFile
                    // One detached hop reads everything off-main: usage, the
                    // pulse (plan + last exchange, same file), and the shared
                    // ProcTable snapshot (TTL-cached; capture blocks ~60ms).
                    let (parsedUsage, parsedPulse, table) = await Task.detached(priority: .utility)
                    { () -> (ConversationUsage?, SessionPulse.Pulse?, ProcTable?) in
                        let u = agent == .codex
                            ? ConversationUsageParser.parseCodex(sessionFile: file)
                            : accumulator.ingest(file: file)
                        let p = SessionPulse.read(sessionFile: file, agent: agent)
                        return (u, p, ProcTable.cached(socketDir: Dtach.directory))
                    }.value
                    var parsed = parsedUsage
                    // Equatable-guarded writes — no re-render churn on quiet ticks.
                    if let parsedPulse, parsedPulse != pulse { pulse = parsedPulse }
                    let facts = coordinator.processFacts(for: convo.id, table: table)
                    if facts != procFacts { procFacts = facts }
                    // Codex carries its 5H/Weekly windows in-file; Claude's only come
                    // from the OAuth usage API (cached/throttled). Merge them in.
                    if agent == .claudeCode {
                        let windows = await ClaudeRateLimits.shared.windows()
                        if !windows.isEmpty { parsed?.rateWindows = windows }
                    }
                    // Carry forward the last-known rate windows when a refresh comes
                    // back with none (a transient stale tail / API hiccup) so the
                    // Usage limits section stays put instead of flickering away.
                    if parsed?.rateWindows.isEmpty == true, let prev = usage?.rateWindows, !prev.isEmpty {
                        parsed?.rateWindows = prev
                    }
                    if Task.isCancelled { break }
                    if let parsed { usage = parsed }
                }
                try? await Task.sleep(for: .seconds(8))
            }
        }
        // Live git state for the room (any conversation — agent or shell).
        // Reset only when the ROOM changes; the poll loop, like the usage one,
        // exists only while this window is visible.
        .onChange(of: conversation?.roomPath.path) {
            gitStatus = nil
            showGitDetails = false
        }
        .task(id: "\(conversation?.roomPath.path ?? "none")-\(windowVisible)") {
            guard windowVisible, let room = conversation?.roomPath else { return }
            while !Task.isCancelled {
                if NSApp.isActive {
                    let status = await Task.detached(priority: .utility) {
                        GitStatusReader.read(roomPath: room)
                    }.value
                    if Task.isCancelled { break }
                    gitStatus = status
                }
                try? await Task.sleep(for: .seconds(6))
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

    // MARK: - Plan (the agent's live todo list, read from the session file)

    private func planSection(_ p: SessionPulse.Pulse) -> some View {
        // Long plans collapse their leading completed steps into one summary
        // row — the glance is "what's current + what's left", not history.
        let todos = p.todos
        let collapse = todos.count > 10
        let visible = collapse ? todos.filter { $0.status != .completed } : todos
        return section("Plan", detail: "\(p.todosDone)/\(todos.count) done") {
            VStack(alignment: .leading, spacing: CHM.Space.xs) {
                if collapse, p.todosDone > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text("\(p.todosDone) completed")
                            .font(CHM.Font.caption).foregroundStyle(.tertiary)
                    }
                }
                ForEach(Array(visible.prefix(10).enumerated()), id: \.offset) { _, todo in
                    todoRow(todo)
                }
                if visible.count > 10 {
                    Text("+\(visible.count - 10) more")
                        .font(CHM.Font.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func todoRow(_ t: SessionPulse.Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch t.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            case .inProgress:
                Image(systemName: "circle.inset.filled")
                    .font(.system(size: 10)).foregroundStyle(CHM.Color.accent)
            case .pending:
                Image(systemName: "circle")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text(t.text)
                .font(CHM.Font.caption)
                .foregroundStyle(t.status == .inProgress ? AnyShapeStyle(.primary)
                                 : t.status == .pending ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(.tertiary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Latest (the last exchange + turn state)

    private func latestSection(_ p: SessionPulse.Pulse, _ convo: Conversation) -> some View {
        let (word, color) = turnChip(convo)
        return VStack(alignment: .leading, spacing: CHM.Space.sm) {
            HStack(spacing: CHM.Space.xs) {
                Text("Latest")
                    .font(CHM.Font.eyebrow)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(word).font(CHM.Font.caption).foregroundStyle(color)
                }
            }
            if let you = p.lastUserText {
                exchangeRow("You", you, lines: 2, primary: false)
            }
            if let agent = p.lastAssistantText {
                exchangeRow(convo.agent.displayName, agent, lines: 4, primary: true)
            }
        }
    }

    private func exchangeRow(_ label: String, _ text: String, lines: Int, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(text)
                .font(CHM.Font.caption)
                .foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Same semantics as the minimap's cell state — one vocabulary everywhere.
    private func turnChip(_ convo: Conversation) -> (String, Color) {
        if coordinator.awaitingPaneIDs.contains(convo.id) { return ("your turn", CHM.Color.attention) }
        if coordinator.liveConversationIDs.contains(convo.id) { return ("working…", CHM.Color.accent) }
        return ("idle", Color.secondary)
    }

    // MARK: - Gauge (the centerpiece)

    private func gaugeSection(_ u: ConversationUsage) -> some View {
        section("Context window") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(u.contextUsedPercent))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(usageColor(u.contextUsedPercent))
                        .monospacedDigit()
                        .animation(CHM.Motion.appear, value: u.contextUsedPercent)
                    Text("full")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
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

    /// 5h | Weekly side by side — label + %, a slim bar, and a clock countdown
    /// to reset (matches the dashboard rate-limit card).
    private func limitsSection(_ u: ConversationUsage) -> some View {
        section("Usage limits") {
            HStack(alignment: .top, spacing: CHM.Space.lg) {
                ForEach(u.rateWindows) { w in
                    windowMeter(w).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func windowMeter(_ w: ConversationUsage.RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(w.label).font(CHM.Font.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int(w.usedPercent))%")
                    .font(CHM.Font.captionEmphasis)
                    .foregroundStyle(usageColor(w.usedPercent))
                    .monospacedDigit()
            }
            usageBar(percent: w.usedPercent)
            if let resets = w.resetsAt {
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text("in \(Self.compactCountdown(to: resets))")
                }
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
    }

    /// "6d 7h" / "4h 50m" / "12m" — the largest two units until reset.
    private static func compactCountdown(to date: Date) -> String {
        let secs = Int(max(0, date.timeIntervalSinceNow))
        let d = secs / 86_400, h = (secs % 86_400) / 3_600, m = (secs % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
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

    // MARK: - Name & note (user-set, persisted per conversation)

    private func labelSection(_ convo: Conversation) -> some View {
        section("Name & note") {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                TextField(convo.previewText ?? "Name this conversation…", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(CHM.Font.bodyEmphasis)
                    .onChange(of: nameDraft) { _, v in labels.setName(v, for: convo.id) }
                ZStack(alignment: .topLeading) {
                    if noteDraft.isEmpty {
                        Text("Leave a note — where you left off, blockers, TODOs…")
                            .font(CHM.Font.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $noteDraft)
                        .font(CHM.Font.caption)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 56)
                        .onChange(of: noteDraft) { _, v in labels.setNote(v, for: convo.id) }
                }
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                    .fill(CHM.Color.fillSubtle))
            }
        }
    }

    // MARK: - Working tree (live git state per room)

    @ViewBuilder private func gitSection(_ g: GitStatus) -> some View {
        section("Working tree") {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: g.detached ? "point.3.connected.trianglepath.dotted" : "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(g.branch.isEmpty ? "—" : g.branch)
                        .font(CHM.Font.captionEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if g.hasUpstream {
                        if g.ahead > 0 { aheadBehind("arrow.up", g.ahead) }
                        if g.behind > 0 { aheadBehind("arrow.down", g.behind) }
                    }
                    Spacer(minLength: 0)
                }
                if g.isClean {
                    Text("clean").font(CHM.Font.caption).foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 8) {
                        Text("\(g.changedCount) file\(g.changedCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        if g.insertions > 0 {
                            Text("+\(g.insertions)").foregroundStyle(Self.gitAdd)
                        }
                        if g.deletions > 0 {
                            Text("−\(g.deletions)").foregroundStyle(CHM.Color.alert)
                        }
                    }
                    .font(CHM.Font.caption)
                    .monospacedDigit()
                    if !g.changedPaths.isEmpty {
                        DisclosureGroup(isExpanded: $showGitDetails) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(g.changedPaths, id: \.self) { path in
                                    Text(path)
                                        .font(CHM.Font.monoSmall)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if g.changedCount > g.changedPaths.count {
                                    Text("+\(g.changedCount - g.changedPaths.count) more")
                                        .font(CHM.Font.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.top, CHM.Space.xs)
                        } label: {
                            Text("Changed files").font(CHM.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func aheadBehind(_ icon: String, _ n: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text("\(n)").font(CHM.Font.caption).monospacedDigit()
        }
        .foregroundStyle(.tertiary)
    }

    /// Muted green for added lines (the design system has no green; +/− reads
    /// best in conventional colors, kept desaturated to match the calm palette).
    private static let gitAdd = Color(red: 0.38, green: 0.72, blue: 0.47)

    // MARK: - Process (state + pid + RAM/CPU, from the shared ProcTable)

    @ViewBuilder private func processSection(_ convo: Conversation) -> some View {
        if convo.agent == .claudeCode || convo.agent == .codex, let f = procFacts,
           f.state != .unknown {
            section("Process") {
                VStack(alignment: .leading, spacing: CHM.Space.sm) {
                    HStack(spacing: 6) {
                        Circle().fill(processColor(f.state)).frame(width: 5, height: 5)
                        Text(processLabel(f.state))
                            .font(CHM.Font.caption).foregroundStyle(.secondary)
                    }
                    if let pid = f.pid { metaRow("PID", "\(pid)", mono: true) }
                    if let rss = f.rssBytes { metaRow("Memory", formatBytes(rss)) }
                    if let cpu = f.cpuPercent { metaRow("CPU", String(format: "%.1f%%", cpu)) }
                }
            }
        }
    }

    private func processLabel(_ s: TabWindowCoordinator.ProcessFacts.State) -> String {
        switch s {
        case .live:       return "Running in a pane"
        case .parked:     return "Parked — running in the background"
        case .notRunning: return "Not running"
        case .unknown:    return "—"
        }
    }

    private func processColor(_ s: TabWindowCoordinator.ProcessFacts.State) -> Color {
        switch s {
        case .live:       return CHM.Color.accent
        case .parked:     return CHM.Color.attention
        case .notRunning: return Color.secondary.opacity(0.5)
        case .unknown:    return Color.secondary.opacity(0.3)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
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
                metaRow("Workspace", convo.roomName)
                metaRow("Path", convo.roomPath.path, mono: true)
                HStack(spacing: CHM.Space.xs) {
                    ActionChip(label: "Copy ID") { copyToPasteboard(convo.id) }
                    if let cmd = TerminalCommand.copyableResume(for: convo) {
                        ActionChip(label: "Copy resume") { copyToPasteboard(cmd) }
                    }
                    ActionChip(label: "Show file") {
                        NSWorkspace.shared.activateFileViewerSelecting([convo.sessionFile])
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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

    private func section(_ title: String, detail: String? = nil,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CHM.Space.sm) {
            HStack(spacing: CHM.Space.xs) {
                Text(title)
                    .font(CHM.Font.eyebrow)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if let detail {
                    Spacer(minLength: 0)
                    Text(detail)
                        .font(CHM.Font.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            content()
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// Loud red banner shown in the Details tab when the conversation's agent has
/// hit its account usage limit ("CODEX BURST"). The limit is account-wide.
private struct BurstBanner: View {
    let agents: Set<AgentKind>

    var body: some View {
        VStack(spacing: 6) {
            ForEach(agents.sorted { $0.rawValue < $1.rawValue }, id: \.self) { agent in
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(BurstDetector.label(for: agent)) BURST")
                            .font(.system(size: 12, weight: .heavy))
                        Text("usage limit reached")
                            .font(CHM.Font.caption)
                            .opacity(0.9)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, CHM.Space.sm)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                        .fill(CHM.Color.alert)
                )
            }
        }
    }
}

/// A small utility chip (Copy ID / Copy resume / Show file) — same quiet
/// fill-and-hover treatment as the port rows.
private struct ActionChip: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(CHM.Font.caption)
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, CHM.Space.sm)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: CHM.Radius.chip)
                    .fill(hovering ? CHM.Color.hoverFill : CHM.Color.fillSubtle))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
