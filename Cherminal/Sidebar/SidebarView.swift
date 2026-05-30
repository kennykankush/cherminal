import SwiftUI

struct SidebarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case byRoom = "By room"
        case byRecent = "Recent"
        var id: String { rawValue }
    }

    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @EnvironmentObject private var pins: PinsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                // Animate only mode-driven swaps (value-scoped, so search/load
                // transitions are untouched). Pairs with the per-list
                // pushTransition; .animation(value:) supplies the transaction
                // the @AppStorage write otherwise loses.
                .animation(CHM.Motion.modeSwitch, value: mode)
        }
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        // Debounced full-text body search. Title/room filtering stays instant
        // (in-memory); this adds matches found inside conversation bodies.
        .task(id: search) {
            let query = search
            guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
                bodyHits = [:]; searchingBodies = false; return
            }
            // Flag "searching" *before* the debounce so a body-only query shows
            // a spinner rather than a false "No matches" during the wait.
            searchingBodies = true
            bodyHits = [:]
            try? await Task.sleep(for: .milliseconds(180))   // debounce
            guard !Task.isCancelled else { return }
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
                RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                    .fill(CHM.Color.hoverFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CHM.Radius.tab, style: .continuous)
                    .strokeBorder(CHM.Color.hairline, lineWidth: 1)
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
                    pinnedSection
                    ForEach(filteredRooms) { room in
                        // Pinned ones are lifted into the Pinned section, so a
                        // room shows only its un-pinned conversations.
                        let convos = room.conversations.filter { !pins.isPinned($0.id) }
                        if !convos.isEmpty {
                            Section {
                                if roomIsExpanded(room) {
                                    ForEach(convos) { convo in
                                        ConversationRow(conversation: convo,
                                                        isLive: coordinator.liveConversationIDs.contains(convo.id),
                                                        isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id))
                                            .tag(convo.id as Conversation.ID?)
                                            .contextMenu { rowMenu(convo) }
                                    }
                                }
                            } header: {
                                RoomDisclosureHeader(
                                    name: room.name,
                                    count: convos.count,
                                    isExpanded: roomIsExpanded(room)
                                ) { toggleRoom(room) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: selection) { _, newID in
                    guard let newID, let convo = registry.conversation(id: newID) else { return }
                    // Defer the section-expansion mutation off the selection
                    // commit to avoid re-entering the NSTableView delegate.
                    DispatchQueue.main.async { expandedRooms.insert(convo.roomPath.path) }
                }
                .onAppear(perform: seedExpandedRoom)
                .transition(pushTransition(towards: .leading))
            case .byRecent:
                List(selection: $selection) {
                    pinnedSection
                    // Pinned ones live in the Pinned section above — don't repeat
                    // them here.
                    ForEach(filteredConversations.filter { !pins.isPinned($0.id) }) { convo in
                        ConversationRow(conversation: convo, showRoom: true,
                                        isLive: coordinator.liveConversationIDs.contains(convo.id),
                                        isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id))
                            .tag(convo.id as Conversation.ID?)
                            .contextMenu { rowMenu(convo) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .transition(pushTransition(towards: .trailing))
            }
        }
    }

    /// Direction-aware transition for the mode swap: content enters/leaves on
    /// the side its toggle lives (By room = leading, Recent = trailing), so the
    /// list pushes in the same direction the selector moves. Plus a fade so the
    /// heavy List swap reads smoothly. Reduce Motion → a plain crossfade.
    private func pushTransition(towards edge: Edge) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: edge).combined(with: .opacity)
    }

    // MARK: - Pinned (cross-room shortcuts)

    private var pinnedConversations: [Conversation] {
        pins.pinnedIDs.compactMap { registry.conversation(id: $0) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Pinned conversations live above the room/recent list as one-click
    /// cross-room shortcuts. They open on tap (not via List selection) so they
    /// don't clash with the same conversation appearing below in its room.
    @ViewBuilder
    private var pinnedSection: some View {
        if !pinnedConversations.isEmpty {
            Section {
                ForEach(pinnedConversations) { convo in
                    ConversationRow(conversation: convo, showRoom: true,
                                    isLive: coordinator.liveConversationIDs.contains(convo.id),
                                    isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id),
                                    isPinned: true)
                        // Pinned rows aren't List-selectable (they open on tap),
                        // so highlight the active one manually for "you are here".
                        .listRowBackground(convo.id == selection ? CHM.Color.activeFill : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { open(convo) }
                        .contextMenu {
                            Button("Open") { open(convo) }
                            Button("Unpin", role: .destructive) { pins.toggle(convo.id) }
                        }
                }
            } header: {
                Text("Pinned")
                    .font(CHM.Font.eyebrow)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
        }
    }

    /// Right-click menu for a conversation row: open it, and pin/unpin.
    @ViewBuilder
    private func rowMenu(_ convo: Conversation) -> some View {
        Button("Open") { open(convo) }
        Button(pins.isPinned(convo.id) ? "Unpin" : "Pin",
               systemImage: pins.isPinned(convo.id) ? "pin.slash" : "pin") {
            pins.toggle(convo.id)
        }
    }

    /// Open a conversation on the next runloop turn — never synchronously from
    /// a row tap/menu, which would re-enter the List's NSTableView delegate.
    private func open(_ convo: Conversation) {
        DispatchQueue.main.async { coordinator.openOrFocus(convo) }
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
                        snippet: bodyHits[convo.sessionFile.path],
                        isLive: coordinator.liveConversationIDs.contains(convo.id),
                        isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id),
                        isPinned: pins.isPinned(convo.id)
                    )
                    .tag(convo.id as Conversation.ID?)
                    .contextMenu { rowMenu(convo) }
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
        // Defer: this mutates the List's own section set from a header button
        // inside the List — doing it synchronously re-enters the NSTableView
        // delegate (same crash class as row selection).
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                if expandedRooms.contains(room.id) {
                    expandedRooms.remove(room.id)
                } else {
                    expandedRooms.insert(room.id)
                }
            }
        }
    }

    /// Open the active conversation's room on first appearance so you land
    /// looking at where you already are.
    private func seedExpandedRoom() {
        guard expandedRooms.isEmpty,
              let selected = selection,
              let convo = registry.conversation(id: selected) else { return }
        // Defer off the List's appear pass to avoid re-entering the table.
        DispatchQueue.main.async { expandedRooms.insert(convo.roomPath.path) }
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
                    .onTapGesture { mode = option }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        // Drive the thumb off the value change, NOT a withAnimation around the
        // mutation: `mode` is @AppStorage-backed and the UserDefaults round-trip
        // drops the change out of the animation transaction (it just snapped).
        // .animation(value:) animates whenever the value lands, regardless.
        .animation(CHM.Motion.pillSlide, value: mode)
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
    /// This conversation is running live in an open tab right now.
    var isLive: Bool = false
    /// Its agent just finished a turn and is waiting on you ("your turn").
    var isAwaiting: Bool = false
    /// Pinned — show a small marker so pin state is visible while browsing.
    var isPinned: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    /// Calm ambient status: blue "your turn" light (full + halo, slow breathe)
    /// when awaiting; a dim blue dot when live-but-working; nothing when idle.
    @ViewBuilder private var statusDot: some View {
        if isAwaiting {
            ZStack {
                Circle().fill(CHM.Color.attentionHalo).frame(width: 13, height: 13).blur(radius: 2.5)
                Circle().fill(CHM.Color.attention).frame(width: 7, height: 7)
            }
            .opacity(breathing ? 1.0 : 0.85)
            .animation(reduceMotion ? nil : CHM.Motion.breathe, value: breathing)
            // Reset on disappear so each awaiting→idle→awaiting cycle produces a
            // real false→true transition and re-arms the repeatForever pulse.
            .onAppear { breathing = true }
            .onDisappear { breathing = false }
            .help("Waiting for you")
        } else if isLive {
            Circle()
                .fill(CHM.Color.attention.opacity(0.30))
                .frame(width: 6, height: 6)
                .help("Running in an open tab")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: CHM.Space.sm) {
            AgentBadge(agent: conversation.agent, size: 17)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    statusDot
                    Text(conversation.previewText ?? "Untitled conversation")
                        .font(.system(size: 13))
                        .foregroundStyle(conversation.previewText == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
            Spacer(minLength: CHM.Space.xs)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(CHM.Color.accent)
                    .padding(.top, 3)
            }
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
