import SwiftUI

/// Bookmark strip above the tabs. Each chip = one saved set of tabs;
/// click to reopen, right-click for rename/delete. Save current tabs with
/// the bookmark icon on the right (also ⌘D). Glass material background
/// to sit comfortably under the unified titlebar above.
struct BookmarksBar: View {
    @EnvironmentObject private var bookmarks: BookmarksManager
    @EnvironmentObject private var tabs: TabsManager
    @EnvironmentObject private var registry: ConversationRegistry
    @EnvironmentObject private var ghostty: Ghostty.App

    @State private var renameTarget: Bookmark?
    @State private var renameText: String = ""
    @State private var showingSavePrompt = false
    @State private var newName: String = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BLV.Space.xs) {
                    if bookmarks.bookmarks.isEmpty {
                        emptyHint
                    } else {
                        ForEach(bookmarks.bookmarks) { bookmark in
                            BookmarkChip(
                                bookmark: bookmark,
                                onOpen: { open(bookmark) },
                                onRename: { startRename(bookmark) },
                                onDelete: { bookmarks.delete(bookmark.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, BLV.Space.md)
                .padding(.vertical, BLV.Space.xs)
            }
            Spacer(minLength: 0)
            saveButton
                .padding(.trailing, BLV.Space.sm)
        }
        .frame(height: BLV.BarHeight.bookmarks)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
        .sheet(isPresented: $showingSavePrompt) { savePromptSheet }
        .sheet(item: $renameTarget) { target in renameSheet(for: target) }
    }

    // MARK: - Sub-views

    private var emptyHint: some View {
        HStack(spacing: BLV.Space.xs) {
            Image(systemName: "bookmark")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("Bookmark current tabs with ⌘D")
                .font(BLV.Font.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, BLV.Space.sm)
    }

    private var saveButton: some View {
        let isEmpty = tabs.tabs.isEmpty
        return Button(action: promptForSave) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEmpty ? .tertiary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: BLV.Radius.chip)
                        .fill(isEmpty ? Color.clear : BLV.Color.hoverFill)
                )
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .keyboardShortcut("d", modifiers: .command)
        .help(isEmpty
              ? "Open tabs to bookmark them"
              : "Save current tabs as a bookmark (⌘D)")
    }

    private var savePromptSheet: some View {
        let count = tabs.tabs.count
        return VStack(alignment: .leading, spacing: BLV.Space.lg) {
            VStack(alignment: .leading, spacing: BLV.Space.xs) {
                Text("New bookmark")
                    .font(.title3.weight(.semibold))
                Text("Saving \(count) open tab\(count == 1 ? "" : "s") so you can reopen them later.")
                    .font(BLV.Font.body)
                    .foregroundStyle(.secondary)
            }
            TextField("Name", text: $newName, prompt: Text("e.g. Fantopy bugfix"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingSavePrompt = false
                    newName = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    bookmarks.create(name: newName, tabs: tabs.snapshot())
                    showingSavePrompt = false
                    newName = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(BLV.Space.xl)
        .frame(width: 400)
    }

    private func renameSheet(for bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: BLV.Space.lg) {
            Text("Rename bookmark")
                .font(.title3.weight(.semibold))
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    bookmarks.rename(bookmark.id, to: renameText)
                    renameTarget = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(BLV.Space.xl)
        .frame(width: 400)
    }

    // MARK: - Actions

    private func open(_ bookmark: Bookmark) {
        guard let app = ghostty.app else { return }
        bookmarks.open(
            bookmark,
            tabs: tabs,
            registry: registry,
            ghosttyApp: app,
            configBuilder: TerminalCommand.surfaceConfig(for:)
        )
    }

    private func promptForSave() {
        guard !tabs.tabs.isEmpty else { return }
        newName = ""
        showingSavePrompt = true
    }

    private func startRename(_ bookmark: Bookmark) {
        renameText = bookmark.name
        renameTarget = bookmark
    }
}

private struct BookmarkChip: View {
    let bookmark: Bookmark
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: BLV.Space.xs) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(BLV.Color.accent.opacity(0.8))
                Text(bookmark.name)
                    .font(BLV.Font.captionEmphasis)
                    .lineLimit(1)
                Text("\(bookmark.tabs.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(BLV.Color.hoverFill)
                    )
            }
            .padding(.horizontal, BLV.Space.sm)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: BLV.Radius.chip)
                    .fill(isHovering ? BLV.Color.hoverFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(BLV.Motion.hover) { isHovering = hovering }
        }
        .help("\(bookmark.tabs.count) tab\(bookmark.tabs.count == 1 ? "" : "s")")
        .contextMenu {
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
