import Combine
import Foundation

/// A user's manual annotations for a conversation: a short custom **name** and a
/// freeform **note**. Pure user data (not derived from the session), persisted
/// locally and keyed by conversation id, so it survives relaunches and isn't
/// tied to the session file. When a custom name is set it becomes the
/// conversation's display name; otherwise the `/rename` / auto title shows.
struct ConversationLabel: Codable, Equatable {
    var name: String = ""
    var note: String = ""
    var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class ConversationLabelsManager: ObservableObject {
    @Published private(set) var labels: [String: ConversationLabel]

    private let defaultsKey = "cherminal.conversationLabels"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ConversationLabel].self, from: data) {
            labels = decoded
        } else {
            labels = [:]
        }
    }

    func label(for id: String) -> ConversationLabel { labels[id] ?? .init() }

    /// True when the user has set a custom name (vs. falling back to the title).
    func hasName(_ id: String) -> Bool {
        !(labels[id]?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The display name for a conversation: the custom name if set, else
    /// `fallback` (the `/rename`/auto title), else "Untitled".
    func displayName(for id: String, fallback: String?) -> String {
        let custom = labels[id]?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let fb = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fb.isEmpty ? "Untitled" : fb
    }

    func setName(_ name: String, for id: String) { update(id) { $0.name = name } }
    func setNote(_ note: String, for id: String) { update(id) { $0.note = note } }

    private func update(_ id: String, _ mutate: (inout ConversationLabel) -> Void) {
        var l = labels[id] ?? .init()
        mutate(&l)
        // Drop the entry entirely when both fields are blank, so cleared labels
        // don't accumulate empty rows.
        if l.isEmpty { labels.removeValue(forKey: id) } else { labels[id] = l }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
