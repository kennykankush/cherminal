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
    /// Full-text body matches: session-file path → matched snippet.
    @State private var bodyHits: [String: String] = [:]
    @State private var searchingBodies = false

    var body: some View {
        VStack(spacing: 0) {
            topControls
            Divider().opacity(0.5)
            list
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // Debounced full-text body search. Title/room filtering stays instant
        // (in-memory); this adds matches found inside conversation bodies.
        .task(id: search) {
            let query = search
            bodyHits = [:]
            guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
            try? await Task.sleep(for: .milliseconds(180))   // debounce
            guard !Task.isCancelled else { return }
            searchingBodies = true
            let hits = await Task.detached(priority: .userInitiated) {
                ConversationSearcher.search(query: query)
            }.value
            guard !Task.isCancelled else { return }
            bodyHits = Dictionary(hits.map { ($0.path, $0.snippet) }, uniquingKeysWith: { a, _ in a })
            searchingBodies = false
        }
    }

    // MARK: - Chrome

    private var topControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search conversations", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )

            ModeToggle(mode: $mode)
        }
        // Top padding clears the traffic-light overlay (hiddenTitleBar window).
        .padding(.top, 28)
        .padding(.horizontal, CHM.Space.md)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var list: some View {
        if registry.isLoading && registry.conversations.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxHeight: .infinity)
        } else if !search.isEmpty {
            searchResultsList
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

    // MARK: - Search results (title/room + full-text body)

    @ViewBuilder
    private var searchResultsList: some View {
        let results = searchResults
        if results.isEmpty {
            if searchingBodies {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            } else {
                emptyState
            }
        } else {
            List(selection: $selection) {
                if searchingBodies {
                    Label("Searching conversations…", systemImage: "magnifyingglass")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.tertiary)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))
                }
                ForEach(results) { convo in
                    ConversationRow(
                        conversation: convo,
                        showRoom: true,
                        snippet: bodyHits[convo.sessionFile.path]
                    )
                    .tag(convo.id as Conversation.ID?)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    /// Conversations matching the query by title/room OR body, most recent
    /// first. Body matches come from the debounced full-text searcher.
    private var searchResults: [Conversation] {
        let needle = search.lowercased()
        let matched = registry.conversations.filter { convo in
            (convo.previewText?.lowercased().contains(needle) ?? false)
            || convo.roomName.lowercased().contains(needle)
            || bodyHits[convo.sessionFile.path] != nil
        }
        return matched.sorted { $0.lastActivityAt > $1.lastActivityAt }
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

// MARK: - Mode toggle

/// A muted, modern segmented toggle — subtle track, soft sliding selection
/// fill (not the heavy system blue). Crisp, pro-dashboard mood.
private struct ModeToggle: View {
    @Binding var mode: SidebarView.Mode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarView.Mode.allCases) { option in
                let selected = mode == option
                Text(option.rawValue)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.10))
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { mode = option }
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer(minLength: CHM.Space.xs)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            // Generous space above each room header so sections read as
            // distinct groups (cf. ChatGPT/Claude sidebars).
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    var showRoom: Bool = false
    /// Matched body excerpt when this row came from a full-text search.
    var snippet: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: CHM.Space.sm) {
            AgentBadge(agent: conversation.agent, size: 17)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
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
                if let snippet {
                    Text(snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
    }
}

private extension Date {
    // One shared formatter — allocating a RelativeDateTimeFormatter per row per
    // render (this is read from every ConversationRow body) is a known hotspot.
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var relativeShort: String {
        Date.relativeFormatter.localizedString(for: self, relativeTo: .now)
    }
}
