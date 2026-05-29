import SwiftUI
import AppKit

struct ContextWatchPane: View {
    enum Tab: String, CaseIterable, Identifiable {
        case context = "Context"
        case pin = "Pin"
        case group = "Group"
        case port = "Port"
        var id: String { rawValue }
    }

    let conversation: Conversation?

    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var bookmarks: BookmarksManager
    @EnvironmentObject private var pins: PinsManager
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @EnvironmentObject private var ports: PortsManager

    @State private var tab: Tab = .context
    @State private var usage: ConversationUsage?
    @State private var renamingGroup: Bookmark?
    @State private var renameText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            switch tab {
            case .context: contextTab
            case .pin: pinTab
            case .group: groupTab
            case .port: portTab
            }
        }
        // Poll dev ports only while the Port tab is visible.
        .onChange(of: tab) { _, newTab in
            if newTab == .port { ports.start() } else { ports.stop() }
        }
        .onDisappear { ports.stop() }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // Load + live-refresh usage for the active conversation. Re-parses
        // every few seconds so the context gauge tracks the conversation as
        // it grows. Fully local — reads the session JSONL only.
        .task(id: conversation?.id) {
            usage = nil
            guard let convo = conversation,
                  convo.agent == .claudeCode || convo.agent == .codex else { return }
            let file = convo.sessionFile
            let agent = convo.agent
            // Claude usage streams append-only — fold in deltas across polls
            // instead of re-reading the whole session each time. (Codex carries
            // a full token_count record in its tail, so it re-reads the tail.)
            let accumulator = ClaudeUsageAccumulator()
            while !Task.isCancelled {
                let parsed = await Task.detached(priority: .utility) {
                    agent == .codex
                        ? ConversationUsageParser.parseCodex(sessionFile: file)
                        : accumulator.ingest(file: file)
                }.value
                if Task.isCancelled { break }
                // Keep the last good reading if a poll found nothing new.
                if let parsed { usage = parsed }
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .alert("Rename group", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Save") {
                if let g = renamingGroup { bookmarks.rename(g.id, to: renameText) }
                renamingGroup = nil
            }
        }
    }

    // MARK: - Context tab

    @ViewBuilder
    private var contextTab: some View {
        if let convo = conversation {
            ScrollView {
                VStack(alignment: .leading, spacing: CHM.Space.xl) {
                    if let usage {
                        contextSection(usage)
                        if !usage.rateWindows.isEmpty { limitsSection(usage) }
                        tokensSection(usage)
                    }
                    sessionSection(convo)
                    roomSection(convo)
                }
                .padding(CHM.Space.xl)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Pin tab (single conversations)

    @ViewBuilder
    private var pinTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CHM.Space.md) {
                if let convo = conversation {
                    Button {
                        pins.toggle(convo.id)
                    } label: {
                        Label(
                            pins.isPinned(convo.id) ? "Unpin this conversation" : "Pin this conversation",
                            systemImage: pins.isPinned(convo.id) ? "pin.slash" : "pin"
                        )
                        .font(CHM.Font.captionEmphasis)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: CHM.Radius.chip).fill(CHM.Color.hoverFill))
                    }
                    .buttonStyle(.plain)
                }

                if pinnedConversations.isEmpty {
                    placeholder("pin", "No pinned conversations",
                                "Pin a conversation to keep it one click away, no matter which room it lives in.")
                } else {
                    ForEach(pinnedConversations) { convo in
                        SavedRow(icon: "pin.fill", title: convo.previewText ?? "Untitled conversation",
                                 subtitle: convo.roomName, count: nil)
                            .onTapGesture { coordinator.openOrFocus(convo) }
                            .contextMenu {
                                Button("Open") { coordinator.openOrFocus(convo) }
                                Button("Unpin", role: .destructive) { pins.toggle(convo.id) }
                            }
                    }
                }
            }
            .padding(CHM.Space.lg)
        }
    }

    private var pinnedConversations: [Conversation] {
        pins.pinnedIDs.compactMap { registry.conversation(id: $0) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    // MARK: - Group tab (saved tab sets)

    @ViewBuilder
    private var groupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CHM.Space.md) {
                Button {
                    let tabs = coordinator.snapshot()
                    if !tabs.isEmpty { bookmarks.create(name: "", tabs: tabs) }
                } label: {
                    Label(
                        coordinator.tabCount > 0
                            ? "Save \(coordinator.tabCount) open tab\(coordinator.tabCount == 1 ? "" : "s") as a group"
                            : "No open tabs to save",
                        systemImage: "square.stack.3d.up"
                    )
                    .font(CHM.Font.captionEmphasis)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: CHM.Radius.chip).fill(CHM.Color.hoverFill))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.tabCount == 0)

                if bookmarks.bookmarks.isEmpty {
                    placeholder("square.stack.3d.up", "No saved groups",
                                "Save the set of tabs you're working in as a group, then reopen them all at once.")
                } else {
                    ForEach(bookmarks.bookmarks) { group in
                        SavedRow(icon: "square.stack.3d.up.fill", title: group.name,
                                 subtitle: nil, count: group.tabs.count)
                            .onTapGesture { bookmarks.open(group, registry: registry, coordinator: coordinator) }
                            .contextMenu {
                                Button("Open") { bookmarks.open(group, registry: registry, coordinator: coordinator) }
                                Button("Rename…") { renameText = group.name; renamingGroup = group }
                                Divider()
                                Button("Delete", role: .destructive) { bookmarks.delete(group.id) }
                            }
                    }
                }
            }
            .padding(CHM.Space.lg)
        }
    }

    // MARK: - Port tab (dev-server port watcher)

    @ViewBuilder
    private var portTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CHM.Space.lg) {
                if ports.ports.isEmpty {
                    placeholder("network", "No dev servers",
                                "Listening ports for servers started in your rooms (frontend, backend, DB) show up here, grouped and tagged with the chat that spawned them.")
                } else {
                    ForEach(DevPort.Category.allCases, id: \.self) { category in
                        let rows = ports.ports.filter { $0.category == category }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: CHM.Space.xs) {
                                Text(category.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.7)
                                ForEach(rows) { p in
                                    PortRow(port: p, chatName: chatName(for: p))
                                        .onTapGesture { openInBrowser(p.port) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(CHM.Space.lg)
        }
    }

    /// Friendly name for the chat/room a port is attributed to.
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

    // MARK: - Usage sections

    private func contextSection(_ u: ConversationUsage) -> some View {
        section("Context window") {
            VStack(alignment: .leading, spacing: CHM.Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: CHM.Space.xs) {
                    Text("\(Int(u.contextUsedPercent))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(usageColor(u.contextUsedPercent))
                        .monospacedDigit()
                    Text("full")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let model = u.modelDisplayName {
                        Text(model)
                            .font(CHM.Font.captionEmphasis)
                            .foregroundStyle(.secondary)
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
                            Text(w.label)
                                .font(CHM.Font.captionEmphasis)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(w.usedPercent))%")
                                .font(CHM.Font.captionEmphasis)
                                .foregroundStyle(usageColor(w.usedPercent))
                                .monospacedDigit()
                        }
                        usageBar(percent: w.usedPercent)
                        if let resets = w.resetsAt {
                            Text("resets \(resets.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func tokensSection(_ u: ConversationUsage) -> some View {
        section("Tokens this session") {
            VStack(spacing: CHM.Space.xs) {
                tokenRow("Input", u.totalInputTokens)
                tokenRow("Output", u.totalOutputTokens)
                tokenRow("Cache read", u.cacheReadTokens)
                tokenRow("Cache write", u.cacheCreateTokens)
                Divider().opacity(0.25).padding(.vertical, 2)
                HStack {
                    Text("Cache hit")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(u.cacheHitPercent))%")
                        .font(CHM.Font.captionEmphasis)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func tokenRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
                .font(CHM.Font.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatTokens(value))
                .font(CHM.Font.monoSmall)
                .foregroundStyle(.primary)
        }
    }

    private func usageBar(percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(usageColor(percent))
                    .frame(width: max(3, geo.size.width * CGFloat(percent / 100)))
                    .animation(.easeOut(duration: 0.25), value: percent)
            }
        }
        .frame(height: 6)
    }

    private func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<70: return .green
        case ..<90: return .orange
        default: return .red
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Metadata sections

    private func sessionSection(_ convo: Conversation) -> some View {
        section("Session") {
            HStack(spacing: CHM.Space.sm) {
                AgentBadge(agent: convo.agent, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(convo.agent.displayName)
                        .font(CHM.Font.bodyEmphasis)
                    Text(convo.previewText ?? "Untitled conversation")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, CHM.Space.xs)
            // Only show a message count we can stand behind: the exact count
            // from the full usage parse (Claude). Hidden otherwise rather than
            // surfacing the head/tail lower bound or Codex's placeholder 0.
            if let count = usage?.messageCount {
                keyValue("Messages", "\(count)")
            }
            if let first = convo.firstMessageAt {
                keyValue("Started", first.formatted(date: .abbreviated, time: .shortened))
            }
            keyValue("Last activity", convo.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func roomSection(_ convo: Conversation) -> some View {
        section("Room") {
            keyValue("Folder", convo.roomName)
            keyValue("Path", convo.roomPath.path, mono: true)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.top, 28)
        .padding(.horizontal, CHM.Space.md)
        .padding(.bottom, CHM.Space.sm)
    }

    private func placeholder(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(CHM.Font.bodyEmphasis)
            Text(detail)
                .font(CHM.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, CHM.Space.xxl)
        .padding(.horizontal, CHM.Space.sm)
    }

    private var emptyState: some View {
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36, weight: .light))
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

    private func keyValue(_ key: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Text(value)
                .font(mono ? CHM.Font.monoSmall : CHM.Font.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(mono ? 3 : 2)
                .truncationMode(.middle)
        }
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let chatName {
                    Text(chatName)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: CHM.Space.xs)
            Image(systemName: hovering ? "arrow.up.forward.app.fill" : "arrow.up.forward.app")
                .font(.system(size: 12))
                .foregroundStyle(hovering ? AnyShapeStyle(CHM.Color.accent) : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, CHM.Space.sm)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: CHM.Radius.chip)
            .fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
        .onHover { hovering = $0 }
        .help("Open http://localhost:\(port.port)")
    }
}

/// A tappable row for a saved pin or group in the context pane.
private struct SavedRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var count: Int?

    var body: some View {
        HStack(spacing: CHM.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(CHM.Color.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: CHM.Space.xs)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, CHM.Space.sm)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: CHM.Radius.chip).fill(Color.primary.opacity(0.04)))
    }
}
