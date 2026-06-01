import Foundation

/// A kanban column (status lane). v1 board is global (one set of columns/tasks
/// across the app), seeded with Todo/Doing/Review/Done.
struct KanbanColumn: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var title: String
    var order: Int

    init(id: UUID = UUID(), title: String, order: Int) {
        self.id = id
        self.title = title
        self.order = order
    }

    /// Default lanes seeded on first run.
    static func seed() -> [KanbanColumn] {
        ["Todo", "Doing", "Review", "Done"].enumerated().map {
            KanbanColumn(title: $0.element, order: $0.offset)
        }
    }
}

/// A task card. `columnID` is its status; `order` its position within the
/// column. Two optional links: `linkedPaneID` is the *live* tie to a grid slot;
/// `linkedConversationID` is the *durable* tie (survives reloads, resolvable via
/// ConversationRegistry). A task may have one, both, or neither.
struct KanbanTask: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var title: String
    var notes: String?
    var columnID: UUID
    var order: Int
    var linkedPaneID: UUID?
    var linkedConversationID: String?
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String,
         notes: String? = nil,
         columnID: UUID,
         order: Int,
         linkedPaneID: UUID? = nil,
         linkedConversationID: String? = nil,
         createdAt: Date = .now,
         updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.notes = notes
        self.columnID = columnID
        self.order = order
        self.linkedPaneID = linkedPaneID
        self.linkedConversationID = linkedConversationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
