import SwiftUI
import AppKit

/// The Details tab of the right-hand inspector — the **Cockpit** layout.
/// One hero: the context ring with the account limit meters riding beside it
/// (each meter carries the deficit watch — actual burn vs an even drain of
/// the window, CodexBar's pace model). Everything else is a flat drawer row
/// whose collapsed state still shows its key fact ("main · clean",
/// "106 msgs · 365 MB"), so the closed panel reads as a summary, not a wall.
/// Drawer open-state persists app-wide (one preference, every tab agrees).
///
/// A brand-new agent chat (process running, no session file yet) gets an
/// explicit "new conversation" state — ring at rest + the account meters,
/// which apply before the first message is ever sent.
struct ContextWatchPane: View {
    let conversation: Conversation?
    /// An agent process is running in the pane but no conversation exists on
    /// disk yet (claude writes nothing until the first message).
    var pendingAgent: AgentKind? = nil

    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var pins: PinsManager
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @EnvironmentObject private var ports: PortsManager
    @EnvironmentObject private var labels: ConversationLabelsManager
    @ObservedObject private var usageWatch = UsageWatch.shared

    @State private var usage: ConversationUsage?
    @State private var pulse: SessionPulse.Pulse?
    @State private var procFacts: TabWindowCoordinator.ProcessFacts?
    @State private var portsExpanded = false
    @State private var gitStatus: GitStatus?
    @State private var nameDraft = ""
    @State private var noteDraft = ""
    /// Which drawers are open — comma-joined keys, persisted app-wide so
    /// every tab's inspector agrees and the preference survives relaunch.
    @AppStorage("cherminal.detailsDrawers") private var openDrawersRaw = "now"
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
            if let pendingAgent, conversation == nil || conversation?.agent == .shell {
                newConversationState(pendingAgent)
                portsFooter
            } else if let convo = conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerBlock(convo)
                            .padding(.bottom, CHM.Space.md)
                        if coordinator.burstingAgents.contains(convo.agent) {
                            BurstBanner(agents: [convo.agent])
                                .padding(.bottom, CHM.Space.md)
                        }
                        if let usage {
                            cockpitHero(usage, agent: convo.agent)
                                .padding(.bottom, CHM.Space.lg)
                        }
                        if pulse?.isEmpty == false { nowDrawer(convo) }
                        noteDrawer(convo)
                        workspaceDrawer(convo)
                        if convo.agent == .claudeCode || convo.agent == .codex {
                            sessionDrawer(convo)
                        }
                        if let usage { tokensDrawer(usage) }
                    }
                    .padding(CHM.Space.lg)
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
            accumulators = [:]
        }
        // Live-refresh usage for the active conversation. Claude folds in
        // append-only deltas via the accumulator (held in @State so a tab
        // switch resumes instead of re-ingesting); Codex re-reads its tail.
        // Fully local — reads the session JSONL only; account windows come
        // from UsageWatch (fed by the coordinator's reconcile). The loop
        // exists ONLY while this window is visible (id includes
        // windowVisible): hidden tabs cost nothing, and selecting a tab
        // restarts the loop with an immediate refresh.
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
                // screen needs the file parse.
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
                    // Account windows. Claude's only live in UsageWatch (OAuth);
                    // codex's ride in-file but go stale once their reset passes —
                    // freshen, and fall back to the account-level watch.
                    if agent == .claudeCode {
                        let windows = usageWatch.windows(for: .claudeCode)
                        if !windows.isEmpty { parsed?.rateWindows = windows }
                    } else {
                        let inFile = RateWindowLaw.freshen(parsed?.rateWindows ?? [])
                        parsed?.rateWindows = inFile.isEmpty ? usageWatch.windows(for: .codex) : inFile
                    }
                    if Task.isCancelled { break }
                    if let parsed, parsed != usage {
                        usage = parsed
                        // Feed the context-fill notification ("90% — compact
                        // soon"); UsageWatch arms/fires with hysteresis.
                        UsageWatch.shared.reportContext(conversationID: convo.id,
                                                        agent: agent,
                                                        room: convo.roomName,
                                                        percent: parsed.contextUsedPercent)
                    }
                }
                try? await Task.sleep(for: .seconds(8))
            }
        }
        // Live git state for the room (any conversation — agent or shell).
        // Reset only when the ROOM changes; the poll loop, like the usage one,
        // exists only while this window is visible.
        .onChange(of: conversation?.roomPath.path) {
            gitStatus = nil
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

    // MARK: - Header (identity + status + pin)

    private func headerBlock(_ convo: Conversation) -> some View {
        HStack(alignment: .center, spacing: CHM.Space.sm) {
            AgentBadge(agent: convo.agent, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(labels.displayName(for: convo.id, fallback: convo.previewText))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(convo.agent.displayName)
                    Text("·").foregroundStyle(.tertiary)
                    Text(convo.roomName)
                }
                .font(CHM.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: CHM.Space.xs)
            statusChip(turnState(convo))
            Button {
                pins.toggle(convo.id)
            } label: {
                Image(systemName: pins.isPinned(convo.id) ? "pin.fill" : "pin")
                    .font(CHM.Font.captionEmphasis)
                    .foregroundStyle(pins.isPinned(convo.id) ? AnyShapeStyle(CHM.Color.accent) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(pins.isPinned(convo.id) ? "Unpin this conversation" : "Pin this conversation")
        }
        .padding(.top, 24)   // clear the traffic-light overlay (hiddenTitleBar)
    }

    /// Live turn state as a quiet capsule — same vocabulary as the minimap.
    private func statusChip(_ state: (word: String, color: Color)) -> some View {
        HStack(spacing: 4) {
            Circle().fill(state.color).frame(width: 5, height: 5)
            Text(state.word).font(CHM.Font.caption).foregroundStyle(state.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(state.color.opacity(0.12)))
    }

    private func turnState(_ convo: Conversation) -> (word: String, color: Color) {
        if coordinator.awaitingPaneIDs.contains(convo.id) { return ("your turn", CHM.Color.attention) }
        if coordinator.liveConversationIDs.contains(convo.id) { return ("working…", CHM.Color.accent) }
        return ("idle", Color.secondary)
    }

    // MARK: - Cockpit hero (ring + limit meters + the deficit watch)

    private func cockpitHero(_ u: ConversationUsage, agent: AgentKind) -> some View {
        VStack(alignment: .leading, spacing: CHM.Space.sm) {
            HStack(alignment: .center, spacing: CHM.Space.lg) {
                contextRing(percent: u.contextUsedPercent)
                VStack(alignment: .leading, spacing: CHM.Space.md) {
                    if u.rateWindows.isEmpty {
                        Text("Account limits unavailable")
                            .font(CHM.Font.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(u.rateWindows) { meterRow($0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(heroSubline(u, agent: agent))
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    /// The hero ring. Brand clay while healthy — it's THE centerpiece, the
    /// one place the accent is spent — shifting to the muted alert red only
    /// at 90%+ (compaction imminent).
    private func contextRing(percent: Double) -> some View {
        ZStack {
            Circle()
                .stroke(CHM.Color.hairline, lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0.005, percent / 100))))
                .stroke(percent >= 90 ? CHM.Color.alert : CHM.Color.accent,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(CHM.Motion.appear, value: percent)
            VStack(spacing: 1) {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(CHM.Motion.appear, value: percent)
                Text("CONTEXT")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 100, height: 100)
        .padding(4)
    }

    /// "590.2k of 1.0M · 376.8k to auto-compact · Fable 5 (1M)".
    private func heroSubline(_ u: ConversationUsage, agent: AgentKind) -> String {
        var parts = ["\(formatTokens(u.contextUsedTokens)) of \(formatTokens(u.contextWindowTokens))"]
        parts.append(agent == .claudeCode
                     ? "\(formatTokens(u.contextRemainingTokens)) to auto-compact"
                     : "\(formatTokens(u.contextRemainingTokens)) left")
        if let model = u.modelDisplayName { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    /// One account window: label + %, a bar with a tick at where an EVEN burn
    /// would sit, and a caption carrying the reset countdown + the deficit
    /// watch verdict.
    private func meterRow(_ w: ConversationUsage.RateWindow) -> some View {
        let pace = PaceLaw.pace(for: w)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(w.label).font(CHM.Font.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int(w.usedPercent))%")
                    .font(CHM.Font.captionEmphasis)
                    .foregroundStyle(usageColor(w.usedPercent))
                    .monospacedDigit()
            }
            meterBar(percent: w.usedPercent, expected: pace?.expectedPercent)
            meterCaption(w, pace: pace)
        }
    }

    private func meterBar(percent: Double, expected: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CHM.Color.hairline)
                Capsule()
                    .fill(usageColor(percent))
                    .frame(width: max(3, geo.size.width * CGFloat(min(100, percent) / 100)))
                    .animation(CHM.Motion.appear, value: percent)
                // The pace tick: where usage WOULD be on an even drain. The
                // gap between fill and tick IS the deficit/reserve, visually.
                if let expected {
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: 8)
                        .offset(x: geo.size.width * CGFloat(min(100, expected) / 100) - 0.75)
                }
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder
    private func meterCaption(_ w: ConversationUsage.RateWindow, pace: PaceLaw.Pace?) -> some View {
        if let detail = w.detail {
            // The extra-usage meter's spend footnote ("$27.63 of $100").
            Text(detail)
                .font(CHM.Font.caption).foregroundStyle(.tertiary).monospacedDigit()
        } else {
            HStack(spacing: 4) {
                if let resets = w.resetsAt {
                    HStack(spacing: 3) {
                        Image(systemName: "clock").font(.system(size: 8))
                        Text(Self.compactCountdown(to: resets))
                    }
                }
                if let pace {
                    Text("·")
                    paceText(pace)
                }
            }
            .font(CHM.Font.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    /// The deficit watch verdict: depleting before reset > deficit/reserve >
    /// on pace. One phrase, color carries the urgency.
    @ViewBuilder
    private func paceText(_ pace: PaceLaw.Pace) -> some View {
        if let eta = pace.runsOutIn {
            Text("runs out in \(Self.compactCountdown(seconds: eta))")
                .foregroundStyle(CHM.Color.alert)
        } else if pace.deltaPercent >= PaceLaw.onPaceBand {
            Text("+\(Int(pace.deltaPercent))% deficit")
                .foregroundStyle(CHM.Color.accent)
        } else if pace.deltaPercent <= -PaceLaw.onPaceBand {
            Text("\(Int(-pace.deltaPercent))% in reserve")
        } else {
            Text("on pace")
        }
    }

    // MARK: - New conversation (agent running, nothing on disk yet)

    private func newConversationState(_ agent: AgentKind) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: CHM.Space.sm) {
                    AgentBadge(agent: agent, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New conversation")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(agent.displayName) · nothing saved yet")
                            .font(CHM.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: CHM.Space.xs)
                    statusChip(("fresh", CHM.Color.accent))
                }
                .padding(.top, 24)
                .padding(.bottom, CHM.Space.md)

                if coordinator.burstingAgents.contains(agent) {
                    BurstBanner(agents: [agent])
                        .padding(.bottom, CHM.Space.md)
                }

                // The ring at rest + the ACCOUNT meters — limits apply before
                // the first message is ever sent.
                let windows = usageWatch.windows(for: agent)
                HStack(alignment: .center, spacing: CHM.Space.lg) {
                    ZStack {
                        Circle().stroke(CHM.Color.hairline, lineWidth: 7)
                        VStack(spacing: 1) {
                            Text("—")
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .foregroundStyle(.tertiary)
                            Text("CONTEXT")
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 100, height: 100)
                    .padding(4)
                    VStack(alignment: .leading, spacing: CHM.Space.md) {
                        if windows.isEmpty {
                            Text("Account limits unavailable")
                                .font(CHM.Font.caption).foregroundStyle(.tertiary)
                        } else {
                            ForEach(windows) { meterRow($0) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, CHM.Space.lg)

                Text("Send the first message and this panel fills in — name & note, the context ring, tokens, and history.")
                    .font(CHM.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, CHM.Space.md)

                if let convo = conversation { workspaceDrawer(convo) }
            }
            .padding(CHM.Space.lg)
        }
    }

    // MARK: - Drawers (flat disclosure rows; collapsed = one-line summary)

    private func isOpen(_ key: String) -> Bool {
        openDrawersRaw.split(separator: ",").contains(Substring(key))
    }

    private func toggleDrawer(_ key: String) {
        var open = Set(openDrawersRaw.split(separator: ",").map(String.init))
        if !open.insert(key).inserted { open.remove(key) }
        openDrawersRaw = open.sorted().joined(separator: ",")
    }

    private func drawer(_ key: String, _ title: String, meta: String? = nil,
                        @ViewBuilder content: () -> some View) -> some View {
        let open = isOpen(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(CHM.Motion.appear) { toggleDrawer(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title)
                        .font(CHM.Font.captionEmphasis)
                        .foregroundStyle(open ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    Spacer(minLength: CHM.Space.sm)
                    if !open, let meta {
                        Text(meta)
                            .font(CHM.Font.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content()
                    .padding(.leading, 14)
                    .padding(.bottom, CHM.Space.md)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(CHM.Color.hairline).frame(height: 1)
        }
    }

    // MARK: Now — what the agent is doing + where you left off

    private func nowDrawer(_ convo: Conversation) -> some View {
        drawer("now", "Now", meta: nowMeta()) {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                if let p = pulse, !p.todos.isEmpty { planRows(p) }
                if let p = pulse, p.lastUserText != nil || p.lastAssistantText != nil {
                    VStack(alignment: .leading, spacing: CHM.Space.sm) {
                        if let you = p.lastUserText {
                            exchangeRow("You", you, lines: 2, primary: false)
                        }
                        if let agent = p.lastAssistantText {
                            exchangeRow(convo.agent.displayName, agent, lines: 4, primary: true)
                        }
                    }
                }
            }
        }
    }

    /// Collapsed "Now" still answers the question: the in-progress step, or
    /// the plan tally, or a snippet of the last reply.
    private func nowMeta() -> String? {
        guard let p = pulse else { return nil }
        if let current = p.todos.first(where: { $0.status == .inProgress }) {
            return "◉ \(current.text)"
        }
        if !p.todos.isEmpty { return "plan \(p.todosDone)/\(p.todos.count)" }
        if let last = p.lastAssistantText { return "↳ \(last)" }
        return nil
    }

    private func planRows(_ p: SessionPulse.Pulse) -> some View {
        // Long plans collapse their leading completed steps into one summary
        // row — the glance is "what's current + what's left", not history.
        let todos = p.todos
        let collapse = todos.count > 10
        let visible = collapse ? todos.filter { $0.status != .completed } : todos
        return VStack(alignment: .leading, spacing: CHM.Space.xs) {
            HStack {
                Spacer(minLength: 0)
                Text("\(p.todosDone)/\(todos.count) done")
                    .font(CHM.Font.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
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

    private func exchangeRow(_ label: String, _ text: String, lines: Int, primary: Bool) -> some View {
        HStack(alignment: .top, spacing: CHM.Space.sm) {
            RoundedRectangle(cornerRadius: 1)
                .fill(primary ? CHM.Color.accent.opacity(0.55) : CHM.Color.hairline)
                .frame(width: 2)
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
    }

    // MARK: Name & note

    private func noteDrawer(_ convo: Conversation) -> some View {
        drawer("note", "Name & note", meta: noteMeta(convo)) {
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
                        .frame(minHeight: 52)
                        .onChange(of: noteDraft) { _, v in labels.setNote(v, for: convo.id) }
                }
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                    .fill(CHM.Color.fillSubtle))
            }
        }
    }

    private func noteMeta(_ convo: Conversation) -> String? {
        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return "“\(note)”" }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return "add"
    }

    // MARK: Workspace (room: git state + location)

    private func workspaceDrawer(_ convo: Conversation) -> some View {
        drawer("workspace", "Workspace", meta: workspaceMeta(convo)) {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                if let g = gitStatus {
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
                        Spacer(minLength: 4)
                        if g.isClean {
                            Text("clean").font(CHM.Font.caption).foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: 6) {
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
                        }
                    }
                    if !g.isClean, !g.changedPaths.isEmpty {
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
                    }
                }
                metaRow("Folder", convo.roomName)
                metaRow("Path", convo.roomPath.path, mono: true)
            }
        }
    }

    private func workspaceMeta(_ convo: Conversation) -> String {
        guard let g = gitStatus else { return convo.roomName }
        let branch = g.branch.isEmpty ? convo.roomName : g.branch
        if g.isClean { return "\(branch) · clean" }
        return "\(branch) · \(g.changedCount) file\(g.changedCount == 1 ? "" : "s")"
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

    // MARK: Session (process vitals + identity metadata + actions)

    private func sessionDrawer(_ convo: Conversation) -> some View {
        drawer("session", "Session", meta: sessionMeta()) {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                if let f = procFacts, f.state != .unknown {
                    HStack(spacing: 6) {
                        Circle().fill(processColor(f.state)).frame(width: 5, height: 5)
                        Text(processLabel(f.state))
                            .font(CHM.Font.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(processVitals(f))
                            .font(CHM.Font.monoSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                // Only an exact, trustworthy count (Claude); hidden otherwise.
                if let count = usage?.messageCount {
                    metaRow("Messages", "\(count)")
                }
                if let first = convo.firstMessageAt {
                    metaRow("Started", first.formatted(date: .abbreviated, time: .shortened))
                }
                metaRow("Last activity", convo.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
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

    private func sessionMeta() -> String? {
        var parts: [String] = []
        if let count = usage?.messageCount { parts.append("\(count) msgs") }
        if let f = procFacts, let rss = f.rssBytes { parts.append(formatBytes(rss)) }
        else if let f = procFacts, f.state == .parked { parts.append("parked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "PID 18289 · 365 MB · 4.6%" — the vitals as one quiet line instead of
    /// three label rows.
    private func processVitals(_ f: TabWindowCoordinator.ProcessFacts) -> String {
        var parts: [String] = []
        if let pid = f.pid { parts.append("PID \(pid)") }
        if let rss = f.rssBytes { parts.append(formatBytes(rss)) }
        if let cpu = f.cpuPercent { parts.append(String(format: "%.1f%%", cpu)) }
        return parts.joined(separator: " · ")
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

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func metaRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CHM.Space.sm) {
            Text(key)
                .font(CHM.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(mono ? CHM.Font.monoSmall : CHM.Font.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(mono ? 2 : 1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: Tokens

    private func tokensDrawer(_ u: ConversationUsage) -> some View {
        drawer("tokens", "Tokens", meta: "\(formatTokens(u.totalTokens)) total") {
            VStack(alignment: .leading, spacing: CHM.Space.xs) {
                tokenRow("Input", u.totalInputTokens)
                tokenRow("Output", u.totalOutputTokens)
                tokenRow("Cache read", u.cacheReadTokens)
                tokenRow("Cache write", u.cacheCreateTokens)
                Text("\(Int(u.cacheHitPercent))% of input served from cache")
                    .font(CHM.Font.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
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

    // MARK: - Shared formatting

    /// "6d 7h" / "4h 50m" / "12m" — the largest two units until reset.
    private static func compactCountdown(to date: Date) -> String {
        compactCountdown(seconds: date.timeIntervalSinceNow)
    }

    private static func compactCountdown(seconds: TimeInterval) -> String {
        let secs = Int(max(0, seconds))
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

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
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
}

/// Loud red banner shown in the Details tab when the conversation's agent has
/// hit its account usage limit ("CLAUDE BURST"). The limit is account-wide.
/// When the account windows know the binding reset, the banner counts down to
/// it — and BurstLaw clears the banner the moment the reset passes, so it can
/// no longer outlive the limit (the stale-banner bug, 2026-06-13).
private struct BurstBanner: View {
    let agents: Set<AgentKind>

    var body: some View {
        VStack(spacing: 6) {
            ForEach(agents.sorted { $0.rawValue < $1.rawValue }, id: \.self) { agent in
                let reset = BurstLaw.bindingReset(UsageWatch.shared.windows(for: agent))
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(BurstDetector.label(for: agent)) BURST")
                            .font(.system(size: 12, weight: .heavy))
                        Text(reset.map { "usage limit reached — resets in \(Self.countdown(to: $0))" }
                             ?? "usage limit reached")
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

    private static func countdown(to date: Date) -> String {
        let secs = Int(max(0, date.timeIntervalSinceNow))
        let d = secs / 86_400, h = (secs % 86_400) / 3_600, m = (secs % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
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
