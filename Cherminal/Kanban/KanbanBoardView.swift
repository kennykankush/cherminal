import SwiftUI

/// The kanban board — column lanes of task cards. Global (one board), cheap (no
/// terminal surfaces), shown in the detail area via the Grid⇄Board toggle. v1
/// interactions: add/edit/delete task, move between columns (context menu),
/// add/rename/delete column. Drag-to-reorder is a fast-follow.
struct KanbanBoardView: View {
    @EnvironmentObject private var kanban: KanbanManager
    @State private var editingTask: KanbanTask?
    @State private var addingColumn = false
    @State private var newColumnTitle = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: CHM.Space.md) {
                ForEach(kanban.columns) { column in
                    KanbanColumnView(column: column, editingTask: $editingTask)
                        .frame(width: 260)
                }
                addColumnLane
            }
            .padding(CHM.Space.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppEnvironment.shared.ghostty.config.backgroundColor)
        .sheet(item: $editingTask) { task in
            KanbanTaskEditor(task: task)
                .environmentObject(kanban)
        }
    }

    private var addColumnLane: some View {
        VStack(alignment: .leading) {
            if addingColumn {
                TextField("Column name", text: $newColumnTitle)
                    .textFieldStyle(.plain)
                    .font(CHM.Font.bodyEmphasis)
                    .onSubmit { commitColumn() }
                    .padding(CHM.Space.sm)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CHM.Color.hoverFill))
            } else {
                Button {
                    addingColumn = true
                } label: {
                    Label("Add column", systemImage: "plus")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 200, alignment: .leading)
    }

    private func commitColumn() {
        kanban.addColumn(title: newColumnTitle)
        newColumnTitle = ""
        addingColumn = false
    }
}

private struct KanbanColumnView: View {
    @EnvironmentObject private var kanban: KanbanManager
    let column: KanbanColumn
    @Binding var editingTask: KanbanTask?
    @State private var adding = false
    @State private var newTitle = ""

    private var tasks: [KanbanTask] { kanban.tasks(in: column) }

    var body: some View {
        VStack(alignment: .leading, spacing: CHM.Space.sm) {
            HStack {
                Text(column.title.uppercased())
                    .font(CHM.Font.eyebrow)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text("\(tasks.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contextMenu {
                Button("Add Task") { adding = true }
                Button("Delete Column", role: .destructive) { kanban.deleteColumn(column) }
            }

            ForEach(tasks) { task in
                KanbanCardView(task: task)
                    .onTapGesture { editingTask = task }
                    .contextMenu { cardMenu(task) }
            }

            if adding {
                TextField("Task title", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { commit() }
                    .padding(CHM.Space.sm)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CHM.Color.hoverFill))
            } else {
                Button { adding = true } label: {
                    Label("Add", systemImage: "plus")
                        .font(CHM.Font.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func cardMenu(_ task: KanbanTask) -> some View {
        Button("Edit") { editingTask = task }
        Menu("Move to") {
            ForEach(kanban.columns.filter { $0.id != column.id }) { dest in
                Button(dest.title) { kanban.move(task, to: dest) }
            }
        }
        Button("Delete", role: .destructive) { kanban.delete(task) }
    }

    private func commit() {
        kanban.addTask(title: newTitle, to: column)
        newTitle = ""
        adding = false
    }
}

private struct KanbanCardView: View {
    let task: KanbanTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let notes = task.notes, !notes.isEmpty {
                Text(notes)
                    .font(CHM.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if task.linkedConversationID != nil || task.linkedPaneID != nil {
                Label("linked", systemImage: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(CHM.Color.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CHM.Space.sm)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CHM.Color.hoverFill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CHM.Color.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

private struct KanbanTaskEditor: View {
    @EnvironmentObject private var kanban: KanbanManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KanbanTask

    init(task: KanbanTask) { _draft = State(initialValue: task) }

    var body: some View {
        VStack(alignment: .leading, spacing: CHM.Space.md) {
            Text("Edit Task").font(CHM.Font.bodyEmphasis)
            TextField("Title", text: $draft.title)
                .textFieldStyle(.roundedBorder)
            Text("Notes").font(CHM.Font.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }))
                .font(.system(size: 13))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CHM.Color.hairline))
            HStack {
                Button("Delete", role: .destructive) { kanban.delete(draft); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { kanban.update(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(CHM.Space.xl)
        .frame(width: 380)
    }
}
