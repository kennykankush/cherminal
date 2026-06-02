import Foundation

/// An agent whose pane was closed ("detached") but whose process is still
/// alive under its `dtach` master — parked in the side rail for monitoring and
/// one-click reattach. State is derived purely from the session JSONL plus
/// master liveness, so a tray cell needs no terminal surface (≈0 memory).
struct DetachedAgent: Identifiable, Equatable {
    let conversation: Conversation
    let detachedAt: Date
    var state: DetachState

    init(conversation: Conversation, detachedAt: Date = Date(), state: DetachState = .working) {
        self.conversation = conversation
        self.detachedAt = detachedAt
        self.state = state
    }

    /// Keyed on the conversation id — also the dtach socket key, so the tray
    /// can never hold two cells for one master.
    var id: String { conversation.id }

    /// Identity + state; the room/agent are immutable once detached.
    static func == (a: DetachedAgent, b: DetachedAgent) -> Bool {
        a.id == b.id && a.state == b.state
    }
}

/// What a parked agent's cell shows, derived from its session file + master.
enum DetachState: Equatable {
    case working     // mid-turn — busy in the background
    case attention   // finished its turn, waiting on you (breathing blue)
    case dead        // master gone (agent exited or crashed) — reattach = cold resume
}
