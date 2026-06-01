import Foundation

/// Source of truth for the (global, v1) kanban board. Mirrors BookmarksManager:
/// in-memory @Published state, cache-backed CRUD. Seeds default columns on first
/// run. Tasks carry an optional live link (paneID) and durable link
/// (conversationID) to the work they track.
@MainActor
final class KanbanManager: ObservableObject {
    @Published private(set) var columns: [KanbanColumn] = []
    @Published private(set) var tasks: [KanbanTask] = []

    private let cache: SessionCache?

    init(cache: SessionCache?) {
        self.cache = cache
        columns = cache?.loadKanbanColumns() ?? []
        tasks = cache?.loadKanbanTasks() ?? []
        if columns.isEmpty {
            let seeded = KanbanColumn.seed()
            seeded.forEach { cache?.saveKanbanColumn($0) }
            columns = seeded
        }
    }

    func tasks(in column: KanbanColumn) -> [KanbanTask] {
        tasks.filter { $0.columnID == column.id }.sorted { $0.order < $1.order }
    }

    // MARK: - Tasks

    func addTask(title: String, to column: KanbanColumn) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let order = (tasks(in: column).map(\.order).max() ?? -1) + 1
        let task = KanbanTask(title: trimmed, columnID: column.id, order: order)
        tasks.append(task)
        cache?.saveKanbanTask(task)
    }

    func update(_ task: KanbanTask) {
        var t = task
        t.updatedAt = .now
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        cache?.saveKanbanTask(t)
    }

    func delete(_ task: KanbanTask) {
        tasks.removeAll { $0.id == task.id }
        cache?.deleteKanbanTask(id: task.id)
    }

    /// Move a task to the end of another column (the drag-between-columns op).
    func move(_ task: KanbanTask, to column: KanbanColumn) {
        var t = task
        t.columnID = column.id
        t.order = (tasks.filter { $0.columnID == column.id && $0.id != t.id }.map(\.order).max() ?? -1) + 1
        update(t)
    }

    func link(_ task: KanbanTask, paneID: UUID?, conversationID: String?) {
        var t = task
        t.linkedPaneID = paneID
        t.linkedConversationID = conversationID
        update(t)
    }

    // MARK: - Columns

    func addColumn(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let column = KanbanColumn(title: trimmed, order: (columns.map(\.order).max() ?? -1) + 1)
        columns.append(column)
        cache?.saveKanbanColumn(column)
    }

    func rename(_ column: KanbanColumn, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = columns.firstIndex(where: { $0.id == column.id }) else { return }
        columns[i].title = trimmed
        cache?.saveKanbanColumn(columns[i])
    }

    /// Delete a column, reassigning its tasks to the first remaining column
    /// (never cascade-delete user tasks).
    func deleteColumn(_ column: KanbanColumn) {
        let fallback = columns.filter { $0.id != column.id }.sorted { $0.order < $1.order }.first
        if let fallback {
            for task in tasks(in: column) { move(task, to: fallback) }
        } else {
            tasks.removeAll { $0.columnID == column.id }
            tasks.filter { $0.columnID == column.id }.forEach { cache?.deleteKanbanTask(id: $0.id) }
        }
        columns.removeAll { $0.id == column.id }
        cache?.deleteKanbanColumn(id: column.id)
    }
}
