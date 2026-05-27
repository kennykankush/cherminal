import SwiftUI

struct SidebarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case byRoom = "By room"
        case byRecent = "Recent"
        var id: String { rawValue }
    }

    @EnvironmentObject private var registry: ConversationRegistry
    @Binding var mode: Mode
    @Binding var selection: Conversation.ID?

    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().opacity(0.5)
            list
        }
        .background(.regularMaterial)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: BLV.Space.sm) {
                Circle()
                    .fill(BLV.Color.accent)
                    .frame(width: 8, height: 8)
                Text("Belvedere")
                    .font(BLV.Font.brand)
                Spacer()
            }
            Text(subtitle)
                .font(BLV.Font.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(BLV.Motion.appear, value: registry.conversations.count)
        }
        // Clear the traffic-light overlay (window has hiddenTitleBar style).
        .padding(.top, 28)
        .padding(.horizontal, BLV.Space.lg)
        .padding(.bottom, BLV.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: BLV.Space.sm) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            TextField("Search", text: $search, prompt: Text("Filter…"))
                .textFieldStyle(.plain)
                .font(BLV.Font.body)
                .padding(.horizontal, BLV.Space.sm)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: BLV.Radius.chip)
                        .fill(BLV.Color.hoverFill)
                )
        }
        .padding(.horizontal, BLV.Space.lg)
        .padding(.bottom, BLV.Space.sm)
    }

    @ViewBuilder
    private var list: some View {
        if registry.isLoading && registry.conversations.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxHeight: .infinity)
        } else if filteredConversations.isEmpty {
            emptyState
        } else {
            switch mode {
            case .byRoom:
                List(selection: $selection) {
                    ForEach(filteredRooms) { room in
                        Section {
                            ForEach(room.conversations) { convo in
                                ConversationRow(conversation: convo)
                                    .tag(convo.id as Conversation.ID?)
                            }
                        } header: {
                            SectionHeader(name: room.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            case .byRecent:
                List(selection: $selection) {
                    ForEach(filteredConversations) { convo in
                        ConversationRow(conversation: convo, showRoom: true)
                            .tag(convo.id as Conversation.ID?)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: BLV.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No conversations yet" : "No matches")
                .font(BLV.Font.bodyEmphasis)
            Text(search.isEmpty
                 ? "Start a Claude Code or Codex session in any ~/dev folder — it'll show up here."
                 : "Try a shorter query.")
                .font(BLV.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BLV.Space.xl)
        }
        .frame(maxHeight: .infinity)
        .padding(.bottom, BLV.Space.xxl)
    }

    // MARK: - Computed

    private var subtitle: String {
        let count = registry.conversations.count
        let suffix = count == 1 ? "conversation" : "conversations"
        return "\(count) \(suffix)"
    }

    private var filteredConversations: [Conversation] {
        guard !search.isEmpty else { return registry.conversations }
        let needle = search.lowercased()
        return registry.conversations.filter {
            ($0.previewText?.lowercased().contains(needle) ?? false)
            || $0.roomName.lowercased().contains(needle)
        }
    }

    private var filteredRooms: [Room] {
        guard !search.isEmpty else { return registry.rooms }
        let needle = search.lowercased()
        return registry.rooms.compactMap { room in
            let matching = room.conversations.filter {
                ($0.previewText?.lowercased().contains(needle) ?? false)
                || room.name.lowercased().contains(needle)
            }
            guard !matching.isEmpty else { return nil }
            return Room(id: room.id, path: room.path, conversations: matching)
        }
    }
}

// MARK: - Row + section header

private struct SectionHeader: View {
    let name: String
    var body: some View {
        Text(name)
            .font(BLV.Font.eyebrow)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.top, BLV.Space.xs)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    var showRoom: Bool = false

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: BLV.Space.sm) {
            AgentBadge(agent: conversation.agent, size: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.previewText ?? "Untitled conversation")
                    .font(BLV.Font.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: BLV.Space.xs) {
                    if showRoom {
                        Text(conversation.roomName)
                            .font(BLV.Font.captionEmphasis)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(conversation.lastActivityAt.relativeShort)
                        .font(BLV.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .onHover { hovering in
            withAnimation(BLV.Motion.hover) { isHovering = hovering }
        }
    }
}

private extension Date {
    var relativeShort: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}
