import SwiftUI

struct ContextWatchPane: View {
    let conversation: Conversation?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let convo = conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: BLV.Space.xl) {
                        section("Room") {
                            keyValue("Path", convo.roomPath.path, mono: true)
                            keyValue("Folder", convo.roomName)
                        }
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
                            keyValue("ID", convo.id, mono: true)
                            keyValue("Messages", "\(convo.messageCount)")
                            if let first = convo.firstMessageAt {
                                keyValue("Started", first.formatted(date: .abbreviated, time: .shortened))
                            }
                            keyValue("Last activity", convo.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        section("Live state") {
                            Text("Files touched + git diff for this turn land here once libghostty's IPC is wired up.")
                                .font(BLV.Font.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, BLV.Space.xs)
                        }
                    }
                    .padding(BLV.Space.xl)
                }
            } else {
                emptyState
            }
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
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
            Text("Open a conversation to see its room, session metadata, and live state.")
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
