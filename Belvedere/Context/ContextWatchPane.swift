import SwiftUI

struct ContextWatchPane: View {
    let conversation: Conversation?

    @State private var usage: ConversationUsage?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let convo = conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: BLV.Space.xl) {
                        if let usage {
                            contextSection(usage)
                            tokensSection(usage)
                        }
                        sessionSection(convo)
                        roomSection(convo)
                    }
                    .padding(BLV.Space.xl)
                }
            } else {
                emptyState
            }
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // Load + live-refresh usage for the active conversation. Re-parses
        // every few seconds so the context gauge tracks the conversation as
        // it grows. Fully local — reads the session JSONL only.
        .task(id: conversation?.id) {
            usage = nil
            guard let convo = conversation, convo.agent == .claudeCode else { return }
            let file = convo.sessionFile
            while !Task.isCancelled {
                let parsed = await Task.detached(priority: .utility) {
                    ConversationUsageParser.parse(sessionFile: file)
                }.value
                if Task.isCancelled { break }
                usage = parsed
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    // MARK: - Usage sections

    private func contextSection(_ u: ConversationUsage) -> some View {
        section("Context window") {
            VStack(alignment: .leading, spacing: BLV.Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: BLV.Space.xs) {
                    Text("\(Int(u.contextUsedPercent))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(usageColor(u.contextUsedPercent))
                        .monospacedDigit()
                    Text("full")
                        .font(BLV.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let model = u.modelDisplayName {
                        Text(model)
                            .font(BLV.Font.captionEmphasis)
                            .foregroundStyle(.secondary)
                    }
                }

                usageBar(percent: u.contextUsedPercent)

                HStack {
                    Text("\(formatTokens(u.contextUsedTokens)) / \(formatTokens(u.contextWindowTokens))")
                    Spacer()
                    Text("\(formatTokens(u.contextRemainingTokens)) left")
                }
                .font(BLV.Font.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
    }

    private func tokensSection(_ u: ConversationUsage) -> some View {
        section("Tokens this session") {
            VStack(spacing: BLV.Space.xs) {
                tokenRow("Input", u.totalInputTokens)
                tokenRow("Output", u.totalOutputTokens)
                tokenRow("Cache read", u.cacheReadTokens)
                tokenRow("Cache write", u.cacheCreateTokens)
                Divider().opacity(0.25).padding(.vertical, 2)
                HStack {
                    Text("Cache hit")
                        .font(BLV.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(u.cacheHitPercent))%")
                        .font(BLV.Font.captionEmphasis)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func tokenRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
                .font(BLV.Font.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatTokens(value))
                .font(BLV.Font.monoSmall)
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
            HStack(spacing: BLV.Space.sm) {
                AgentBadge(agent: convo.agent, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(convo.agent.displayName)
                        .font(BLV.Font.bodyEmphasis)
                    Text(convo.previewText ?? "Untitled conversation")
                        .font(BLV.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, BLV.Space.xs)
            keyValue("Messages", "\(convo.messageCount)")
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
        HStack(spacing: BLV.Space.sm) {
            Text("Context")
                .font(BLV.Font.eyebrow)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
        }
        .padding(.top, 28)
        .padding(.horizontal, BLV.Space.lg)
        .padding(.bottom, BLV.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: BLV.Space.sm) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing selected")
                .font(BLV.Font.bodyEmphasis)
            Text("Open a conversation to see its context window, tokens, and session.")
                .font(BLV.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BLV.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, BLV.Space.xxl)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: BLV.Space.sm) {
            Text(title)
                .font(BLV.Font.eyebrow)
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
                .font(mono ? BLV.Font.monoSmall : BLV.Font.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(mono ? 3 : 2)
                .truncationMode(.middle)
        }
    }
}
