import SwiftUI

struct SidebarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        // Raw values are the PERSISTED @AppStorage tokens — keep them stable
        // ("By room" predates the workspaces naming); `label` is what renders.
        case byRoom = "By room"
        case byRecent = "Recent"
        case deep = "Deep"   // recent (≤7d) + high session volume — the intensive sessions
        var id: String { rawValue }

        /// User-facing name. "Rooms" are called WORKSPACES in the UI (the
        /// folder you work in); the pane-grid type that happens to be named
        /// `Workspace` in code is never user-visible.
        var label: String {
            switch self {
            case .byRoom: "Workspaces"
            case .byRecent: "Recent"
            case .deep: "Deep"
            }
        }
    }

    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var coordinator: TabWindowCoordinator
    @EnvironmentObject private var pins: PinsManager
    @EnvironmentObject private var bookmarks: BookmarksManager
    @EnvironmentObject private var backgroundAgents: BackgroundAgentsMonitor
    @Binding var mode: Mode
    @Binding var selection: Conversation.ID?

    @State private var search: String = ""
    @State private var expandedRooms: Set<String> = []
    /// Full-text body matches: session-file path → matched snippet.
    @State private var bodyHits: [String: String] = [:]
    @State private var searchingBodies = false
    /// Session-file sizes (bytes) for Deep mode's recent subset — the volume
    /// signal (a head+tail parse can't count messages truthfully, so size is
    /// the honest metric). Filled off-main when Deep is shown, keyed by id.
    @State private var deepSizes: [String: Int64] = [:]
    /// Rows shown per list before "Show more" — caps the otherwise huge sidebar.
    @State private var displayLimit = 50
    /// Minimum session size (bytes) for Deep mode — the size-filter chips.
    @AppStorage("cherminal.deepMinBytes") private var deepMinBytes = 0
    /// git branch per workspace path — fetched ONCE when a workspace expands
    /// (read-only `git`, off-main), never polled: ~48 workspaces × polling
    /// would be a subprocess storm for an ambient label.
    @State private var roomBranches: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            topControls
            Divider().opacity(0.5)
            // ONE persistent List for every mode. Each mode used to be its own
            // List, and switching slid the whole NSTableView out with a
            // move-transition while another slid in — heavy, and any registry
            // publish mid-flight re-laid-out the in-flight transition (the
            // stutter), multiplied across every open tab's sidebar copy. Now
            // the table view persists and mode just swaps its CONTENT,
            // instantly — the toggle thumb's slide is the feedback (Raycast
            // rule: high-frequency switches shouldn't animate content).
            list
            sidebarFooter
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
        // Stat the recent subset for Deep mode's size ranking when Deep opens.
        // Keyed on the MODE only — the old key also included
        // registry.conversations.count, so every incremental publish restarted
        // this task while Deep was visible (more churn during switches).
        .task(id: mode) {
            if mode == .deep { await loadDeepSizes() }
        }
        // New sessions appearing while Deep is open still get sized.
        .onChange(of: registry.conversations.count) {
            if mode == .deep { Task { await loadDeepSizes() } }
        }
        // Reset the "Show more" cap when the list's scope changes.
        .onChange(of: mode) { displayLimit = 50 }
        .onChange(of: search) { displayLimit = 50 }
        .onChange(of: deepMinBytes) { displayLimit = 50 }
        // Fetch the git branch for newly-expanded workspaces (once each).
        .onChange(of: expandedRooms) { _, expanded in
            let missing = expanded.subtracting(roomBranches.keys)
            guard !missing.isEmpty else { return }
            Task.detached(priority: .utility) {
                var found: [String: String] = [:]
                for path in missing {
                    if let status = GitStatusReader.read(roomPath: URL(fileURLWithPath: path)),
                       !status.branch.isEmpty {
                        found[path] = status.branch
                    } else {
                        found[path] = ""   // not a repo — cache the miss too
                    }
                }
                let resolved = found
                await MainActor.run { roomBranches.merge(resolved) { _, new in new } }
            }
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
            if mode == .deep { deepSizeChips }
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
        } else if search.isEmpty && registry.conversations.isEmpty {
            emptyState
        } else {
            // ONE List, always mounted — mode/search swap its CONTENT only.
            List(selection: $selection) {
                if !search.isEmpty {
                    searchSection
                } else {
                    newTabRow
                    groupsSection
                    pinnedSection
                    backgroundSection
                    switch mode {
                    case .byRoom:   workspaceSections
                    case .byRecent: recentRows
                    case .deep:     deepRows
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: selection) { _, newID in
                guard let newID, let convo = registry.conversation(id: newID) else { return }
                // Defer the section-expansion mutation off the selection
                // commit to avoid re-entering the NSTableView delegate. (Also
                // means a pick made in Recent lands on an open workspace.)
                DispatchQueue.main.async { expandedRooms.insert(convo.roomPath.path) }
            }
            .onAppear(perform: seedExpandedRoom)
        }
    }

    // MARK: - Footer (quiet status strip, cf. the desktop-app references)

    private static let appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }()

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Text("Cherminal \(Self.appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 6)
                let tabs = coordinator.tabCount
                let parked = coordinator.detachedAgents.count
                Text(parked > 0 ? "\(tabs) tab\(tabs == 1 ? "" : "s") · \(parked) parked"
                                : "\(tabs) tab\(tabs == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, CHM.Space.md)
            .padding(.vertical, 5)
        }
    }

    // MARK: - Top utility ("New chat"-style)

    /// The Claude-desktop-style action row at the very top of the list.
    private var newTabRow: some View {
        HStack(spacing: CHM.Space.sm) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 17)
            Text("New Tab")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 6)
            Text("⌘T")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            DispatchQueue.main.async { coordinator.openFreshShell() }
        }
        .help("Open a new terminal tab")
    }

    // MARK: - Background (supervisor sessions you can't see in a pane)

    /// Sessions registered with claude's background-agent supervisor that
    /// AREN'T already open in this app — headless dispatched agents and
    /// sessions running in other terminals. Click to attach into a tab
    /// (`claude attach`; the session keeps running, ^Z detaches).
    @ViewBuilder private var backgroundSection: some View {
        let visible = backgroundAgents.sessions.filter {
            !coordinator.isShowing(conversationID: $0.sessionId)
        }
        if !visible.isEmpty {
            Section {
                ForEach(visible) { session in
                    BackgroundSessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            DispatchQueue.main.async {
                                coordinator.attachBackgroundSession(session)
                            }
                        }
                        .contextMenu {
                            Button("Attach in New Tab") {
                                DispatchQueue.main.async {
                                    coordinator.attachBackgroundSession(session)
                                }
                            }
                        }
                }
            } header: {
                Text("Background")
                    .font(CHM.Font.eyebrow)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
        }
    }

    // MARK: - Mode content (rows inside the one shared List)

    /// Workspaces (the folders you work in), collapsible. Pinned ones are
    /// lifted into the Pinned section, so a workspace shows only its
    /// un-pinned conversations. Headers carry a live/awaiting status dot, and
    /// expanded workspaces show their git branch (fetched once on expand).
    @ViewBuilder private var workspaceSections: some View {
        ForEach(filteredRooms) { room in
            let convos = room.conversations.filter { !pins.isPinned($0.id) }
            if !convos.isEmpty {
                Section {
                    if roomIsExpanded(room) {
                        ForEach(convos) { convo in
                            ConversationRow(conversation: convo,
                                            isLive: coordinator.liveConversationIDs.contains(convo.id),
                                            isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id),
                                            isSuperseded: registry.supersededIDs.contains(convo.id))
                                .tag(convo.id as Conversation.ID?)
                                .contextMenu { rowMenu(convo) }
                        }
                    }
                } header: {
                    RoomDisclosureHeader(
                        name: room.name,
                        count: convos.count,
                        isExpanded: roomIsExpanded(room),
                        status: workspaceStatus(room),
                        branch: roomIsExpanded(room) ? roomBranches[room.id] : nil
                    ) { toggleRoom(room) }
                }
            }
        }
    }

    /// A workspace's at-a-glance status: an agent inside is waiting on you
    /// (attention) > something is live (working) > quiet.
    private func workspaceStatus(_ room: Room) -> RoomDisclosureHeader.Status {
        var live = false
        for convo in room.conversations {
            if coordinator.awaitingTurnIDs.contains(convo.id) { return .awaiting }
            if coordinator.liveConversationIDs.contains(convo.id) { live = true }
        }
        return live ? .live : .none
    }

    /// Recent across all workspaces, capped with "Show more".
    @ViewBuilder private var recentRows: some View {
        let all = filteredConversations.filter { !pins.isPinned($0.id) }
        ForEach(all.prefix(displayLimit)) { convo in
            ConversationRow(conversation: convo, showRoom: true,
                            isLive: coordinator.liveConversationIDs.contains(convo.id),
                            isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id),
                            isSuperseded: registry.supersededIDs.contains(convo.id))
                .tag(convo.id as Conversation.ID?)
                .contextMenu { rowMenu(convo) }
        }
        showMoreRow(total: all.count)
    }

    /// Deep: recent intensive sessions ranked by size. Loading/empty render as
    /// calm in-list rows so the List itself never swaps out.
    @ViewBuilder private var deepRows: some View {
        if deepSizes.isEmpty {
            HStack {
                Spacer(); ProgressView().controlSize(.small); Spacer()
            }
            .listRowInsets(EdgeInsets(top: 24, leading: 8, bottom: 8, trailing: 8))
        } else if deepConversations.isEmpty {
            deepEmptyRow
        } else {
            let all = deepConversations.filter { !pins.isPinned($0.id) }
            ForEach(all.prefix(displayLimit)) { convo in
                ConversationRow(conversation: convo, showRoom: true,
                                volume: formatBytes(deepSizes[convo.id] ?? 0),
                                isLive: coordinator.liveConversationIDs.contains(convo.id),
                                isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id),
                                isSuperseded: registry.supersededIDs.contains(convo.id))
                    .tag(convo.id as Conversation.ID?)
                    .contextMenu { rowMenu(convo) }
            }
            showMoreRow(total: all.count)
        }
    }

    /// Search results as in-list rows (title/room matches instantly, body
    /// matches streaming in behind the debounce).
    @ViewBuilder private var searchSection: some View {
        if searchingBodies {
            Label("Searching conversations…", systemImage: "magnifyingglass")
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))
        }
        let results = searchResults
        if results.isEmpty && !searchingBodies {
            Text("No matches — try a shorter query.")
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 8))
        }
        ForEach(results) { convo in
            ConversationRow(
                conversation: convo,
                showRoom: true,
                snippet: bodyHits[convo.sessionFile.path],
                isLive: coordinator.liveConversationIDs.contains(convo.id),
                isAwaiting: coordinator.awaitingTurnIDs.contains(convo.id),
                isPinned: pins.isPinned(convo.id),
                isSuperseded: registry.supersededIDs.contains(convo.id)
            )
            .tag(convo.id as Conversation.ID?)
            .contextMenu { rowMenu(convo) }
        }
    }

    /// Recent (≤7 days) intensive sessions, ranked by session-file SIZE — the
    /// reliable volume signal. Biggest first. Sizes are stat'd lazily into
    /// `deepSizes` when Deep is shown; before that this is empty.
    private var deepConversations: [Conversation] {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let minBytes = Int64(max(deepMinBytes, 1))   // ≥1 also drops unstat'd (size 0)
        return registry.conversations
            .filter { $0.lastActivityAt >= cutoff && (deepSizes[$0.id] ?? 0) >= minBytes }
            .sorted { (deepSizes[$0.id] ?? 0) > (deepSizes[$1.id] ?? 0) }
    }

    /// Size-cutoff chips for Deep mode — filter by session volume.
    private var deepSizeChips: some View {
        let tiers: [(String, Int)] = [
            ("All", 0), ("1MB+", 1_048_576), ("10MB+", 10_485_760), ("100MB+", 104_857_600),
        ]
        return HStack(spacing: 5) {
            ForEach(tiers, id: \.1) { tier in
                let on = deepMinBytes == tier.1
                Text(tier.0)
                    .font(.system(size: 11, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(on ? CHM.Color.activeFill : CHM.Color.fillSubtle))
                    .contentShape(Capsule())
                    .onTapGesture { deepMinBytes = tier.1 }
            }
            Spacer(minLength: 0)
        }
    }

    /// Stat the last-7-days conversations' session files (off-main) for their real
    /// sizes. Cheap — the recent subset is small and stat is ~free.
    private func loadDeepSizes() async {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let recent = registry.conversations
            .filter { $0.lastActivityAt >= cutoff }
            .map { ($0.id, $0.sessionFile) }
        let sizes = await Task.detached(priority: .utility) { () -> [String: Int64] in
            var out: [String: Int64] = [:]
            for (id, url) in recent {
                if let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { out[id] = Int64(n) }
            }
            return out
        }.value
        deepSizes = sizes
    }

    private func formatBytes(_ n: Int64) -> String {
        if n >= 1_048_576 { return String(format: "%.0f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }

    /// Load-on-demand footer (ChatGPT/Claude-style) — caps a long list and
    /// reveals more in batches instead of rendering thousands of rows.
    @ViewBuilder private func showMoreRow(total: Int) -> some View {
        if total > displayLimit {
            Button { displayLimit += 50 } label: {
                Text("Show \(min(50, total - displayLimit)) more · \(total - displayLimit) hidden")
                    .font(CHM.Font.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }
    }

    /// Deep's calm empty state, as an in-list row (the List never swaps out).
    private var deepEmptyRow: some View {
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: "flame")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No intensive sessions")
                .font(CHM.Font.captionEmphasis)
                .foregroundStyle(.secondary)
            Text(deepMinBytes > 0
                 ? "Nothing over \(formatBytes(Int64(deepMinBytes))) in the last 7 days. Try a smaller cutoff."
                 : "Nothing heavy in the last 7 days yet.")
                .font(CHM.Font.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets(top: 28, leading: 12, bottom: 8, trailing: 12))
    }

    // MARK: - Groups (saved tab sets, surfaced in-sidebar)

    /// Saved tab-groups, pinned at the very top of the sidebar. When there are
    /// none, the section still shows a calm prompt — "Bookmark your N tabs" —
    /// so the feature is discoverable without hunting through the menu bar.
    /// Hidden only when there's genuinely nothing to show or save.
    @ViewBuilder
    private var groupsSection: some View {
        if !bookmarks.bookmarks.isEmpty || coordinator.tabCount > 0 {
            Section {
                ForEach(bookmarks.bookmarks) { group in
                    groupRow(group)
                }
                if coordinator.tabCount > 0 { saveTabsRow }
            } header: {
                Text("Groups")
                    .font(CHM.Font.eyebrow)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
        }
    }

    private func groupRow(_ group: Bookmark) -> some View {
        HStack(spacing: CHM.Space.sm) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 17)
            Text(group.name.isEmpty ? "Untitled" : group.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(group.workspaces.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openGroup(group) }
        .contextMenu {
            Button("Open") { openGroup(group) }
            Button("Delete", role: .destructive) { bookmarks.delete(group.id) }
        }
    }

    /// The discovery affordance. Empty → an inviting two-line pitch that says
    /// what a group is *for*; once groups exist → a quiet single line to add
    /// another. Both save the open tabs.
    @ViewBuilder
    private var saveTabsRow: some View {
        let n = coordinator.tabCount
        let tabWord = n == 1 ? "tab" : "tabs"
        Group {
            if bookmarks.bookmarks.isEmpty {
                HStack(spacing: CHM.Space.sm) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 17)
                    VStack(alignment: .leading, spacing: 1) {
                        // "Group", not "workspace" — workspaces are the FOLDERS
                        // in the sidebar; this saves the open tab set.
                        Text("Save tabs as group")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("Reopen these \(n) \(tabWord) — every pane — anytime")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            } else {
                HStack(spacing: CHM.Space.sm) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 17)
                    Text("Save these \(n) \(tabWord)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { saveCurrentTabs() }
        .help("Save the open tabs as a group you can reopen later")
    }

    /// Open every tab in a group. Deferred to the next runloop like the other
    /// row actions, so the mutation doesn't re-enter the List's table delegate.
    private func openGroup(_ group: Bookmark) {
        DispatchQueue.main.async {
            bookmarks.open(group, registry: registry, coordinator: coordinator)
        }
    }

    private func saveCurrentTabs() {
        let workspaces = coordinator.groupSnapshot()
        guard !workspaces.isEmpty else { return }
        DispatchQueue.main.async { bookmarks.create(name: "", workspaces: workspaces) }
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
                                    isPinned: true,
                                    isSuperseded: registry.supersededIDs.contains(convo.id))
                        // Pinned rows aren't List-selectable (they open on tap),
                        // so highlight the active one manually for "you are here".
                        .listRowBackground(convo.id == selection ? CHM.Color.activeFill : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { open(convo) }
                        .contextMenu {
                            Button("Open") { open(convo) }
                            Button("Open as Pane", systemImage: "rectangle.split.2x1") { openAsPane(convo) }
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

    /// Right-click menu for a conversation row: open it (new tab), open as a
    /// pane in the current grid, and pin/unpin.
    @ViewBuilder
    private func rowMenu(_ convo: Conversation) -> some View {
        Button("Open") { open(convo) }
        Button("Open as Pane", systemImage: "rectangle.split.2x1") { openAsPane(convo) }
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

    /// Drop a conversation into the active window's grid as a new pane.
    private func openAsPane(_ convo: Conversation) {
        DispatchQueue.main.async { coordinator.openConversationInPane(convo) }
    }

    private var emptyState: some View {
        VStack(spacing: CHM.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No conversations yet" : "No matches")
                .font(CHM.Font.bodyEmphasis)
            Text(search.isEmpty
                 ? "Start a Claude Code or Codex session in any workspace folder — it'll show up here."
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
                Text(option.label)
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
    /// At-a-glance workspace state: an agent waiting on you beats merely live.
    enum Status { case none, live, awaiting }

    let name: String
    let count: Int
    let isExpanded: Bool
    var status: Status = .none
    /// git branch, shown when expanded (empty/nil = not a repo / unknown).
    var branch: String? = nil
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 1) {
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
                    statusDot
                    Spacer(minLength: CHM.Space.xs)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if let branch, !branch.isEmpty, isExpanded {
                    Text(branch)
                        .font(CHM.Font.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 15)   // aligns under the name
                }
            }
            // Generous space above each workspace header so sections read as
            // distinct groups (cf. ChatGPT/Claude sidebars).
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }

    /// Quiet roll-up of the workspace's agents (cf. the spaces rail pattern):
    /// blue = something here is waiting on you; dim = live and working.
    @ViewBuilder private var statusDot: some View {
        switch status {
        case .awaiting:
            Circle().fill(CHM.Color.attention).frame(width: 5, height: 5)
                .help("An agent here is waiting for you")
        case .live:
            Circle().fill(CHM.Color.attention.opacity(0.3)).frame(width: 5, height: 5)
                .help("An agent here is running")
        case .none:
            EmptyView()
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    var showRoom: Bool = false
    /// A volume label ("62 MB") shown after the timestamp — set in Deep mode.
    var volume: String? = nil
    /// Matched body excerpt when this row came from a full-text search.
    var snippet: String? = nil
    /// This conversation is running live in an open tab right now.
    var isLive: Bool = false
    /// Its agent just finished a turn and is waiting on you ("your turn").
    var isAwaiting: Bool = false
    /// Pinned — show a small marker so pin state is visible while browsing.
    var isPinned: Bool = false
    /// This session was compacted and continued in a newer one — dim it and
    /// badge it so the pair reads as one chain, not a confusing duplicate.
    var isSuperseded: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Calm ambient status: blue "your turn" light (full + halo, slow breathe)
    /// when awaiting; a dim blue dot when live-but-working; nothing when idle.
    /// The breathe is wall-clock-driven (CHM.Phase + TimelineView) so list
    /// re-renders can never reset or desync it — the old @State repeatForever
    /// restarted on every render pass.
    @ViewBuilder private var statusDot: some View {
        if isAwaiting {
            Group {
                if reduceMotion {
                    attentionLight.opacity(0.95)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
                        attentionLight
                            .opacity(0.82 + 0.18 * CHM.Phase.breathe(context.date, period: 3.0))
                    }
                }
            }
            .help("Waiting for you")
        } else if isLive {
            Circle()
                .fill(CHM.Color.attention.opacity(0.30))
                .frame(width: 6, height: 6)
                .help("Running in an open tab")
        }
    }

    private var attentionLight: some View {
        ZStack {
            Circle().fill(CHM.Color.attentionHalo).frame(width: 13, height: 13).blur(radius: 2.5)
            Circle().fill(CHM.Color.attention).frame(width: 7, height: 7)
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
                    if isSuperseded {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .help("Compacted — continued in a newer session")
                    }
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
                    if let volume {
                        Text("·").foregroundStyle(.quaternary)
                        Text(volume)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
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
        .opacity(isSuperseded ? 0.5 : 1)
        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
    }
}

/// A supervisor session running outside this app (headless, or in another
/// terminal). Same row anatomy as ConversationRow: mark, title, context line,
/// quiet status dot — blue when it's blocked waiting on you.
private struct BackgroundSessionRow: View {
    let session: BackgroundSession

    var body: some View {
        HStack(alignment: .top, spacing: CHM.Space.sm) {
            AgentBadge(agent: .claudeCode, size: 17)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if session.needsYou {
                        Circle().fill(CHM.Color.attention).frame(width: 6, height: 6)
                    } else if session.isBusy {
                        Circle().fill(CHM.Color.attention.opacity(0.3)).frame(width: 6, height: 6)
                    }
                    Text(session.name?.isEmpty == false ? session.name! : "Untitled session")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    Text(session.roomName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·").foregroundStyle(.quaternary)
                    Text(session.needsYou ? (session.waitingFor ?? "waiting for you")
                                          : session.status)
                        .foregroundStyle(session.needsYou ? AnyShapeStyle(CHM.Color.attention)
                                                          : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: CHM.Space.xs)
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
        .help("Running under the supervisor — click to attach (^Z detaches, it keeps running)")
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
