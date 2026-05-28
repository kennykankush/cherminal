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
    @State private var expandedRooms: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            topControls
            Divider().opacity(0.5)
            list
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
    }

    // MARK: - Chrome

    private var topControls: some View {
        VStack(spacing: CHM.Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(CHM.Font.body)
            }
            .padding(.horizontal, CHM.Space.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: CHM.Radius.chip)
                    .fill(CHM.Color.hoverFill)
            )

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        // Top padding clears the traffic-light overlay (hiddenTitleBar window).
        .padding(.top, 28)
        .padding(.horizontal, CHM.Space.md)
        .padding(.bottom, CHM.Space.sm)
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
                            if roomIsExpanded(room) {
                                ForEach(room.conversations) { convo in
                                    ConversationRow(conversation: convo)
                                        .tag(convo.id as Conversation.ID?)
                                }
                            }
                        } header: {
                            RoomDisclosureHeader(
                                name: room.name,
                                count: room.conversations.count,
                                isExpanded: roomIsExpanded(room)
                            ) { toggleRoom(room) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: selection) { _, newID in
                    guard let newID, let convo = registry.conversation(id: newID) else { return }
                    expandedRooms.insert(convo.roomPath.path)
                }
                .onAppear(perform: seedExpandedRoom)
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
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No conversations yet" : "No matches")
                .font(CHM.Font.bodyEmphasis)
            Text(search.isEmpty
                 ? "Start a Claude Code or Codex session in any ~/dev folder — it'll show up here."
                 : "Try a shorter query.")
                .font(CHM.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CHM.Space.xl)
        }
        .frame(maxHeight: .infinity)
        .padding(.bottom, CHM.Space.xxl)
    }

    // MARK: - Computed

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

    // MARK: - Section expansion

    /// A room is open when the user expanded it, or whenever a search is
    /// active (so matches are always visible). Collapsed by default to tame
    /// the ~48-room flood.
    private func roomIsExpanded(_ room: Room) -> Bool {
        !search.isEmpty || expandedRooms.contains(room.id)
    }

    private func toggleRoom(_ room: Room) {
        withAnimation(.easeOut(duration: 0.2)) {
            if expandedRooms.contains(room.id) {
                expandedRooms.remove(room.id)
            } else {
                expandedRooms.insert(room.id)
            }
        }
    }

    /// Open the active conversation's room on first appearance so you land
    /// looking at where you already are.
    private func seedExpandedRoom() {
        guard expandedRooms.isEmpty,
              let selected = selection,
              let convo = registry.conversation(id: selected) else { return }
        expandedRooms.insert(convo.roomPath.path)
    }
}

// MARK: - Row + section header

private struct RoomDisclosureHeader: View {
    let name: String
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(name)
                    .font(CHM.Font.eyebrow)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: CHM.Space.xs)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    var showRoom: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: CHM.Space.sm) {
            AgentBadge(agent: conversation.agent, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.previewText ?? "Untitled conversation")
                    .font(.system(size: 13))
                    .foregroundStyle(conversation.previewText == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if showRoom {
                        Text(conversation.roomName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.quaternary)
                    }
                    Text(conversation.lastActivityAt.relativeShort)
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
    }
}

private extension Date {
    var relativeShort: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}
