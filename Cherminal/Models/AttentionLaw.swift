import Foundation

/// THE law for the "your turn" attention light — the unread-badge semantics
/// that decide when the sidebar light turns on, stays off, and clears. Pure,
/// so the rules are testable; the coordinator feeds it per-pane facts each
/// reconcile pass and applies the verdicts.
///
/// Semantics (unread badge, not a live status):
///   • VIEWING the pane (its window key + it's the active pane) clears the
///     light and records the file size as "read up to here" — so re-focusing
///     later can't relight for a turn you already saw.
///   • A completed turn lights the badge ONLY if the file has grown past the
///     recorded seen-size — a genuinely NEW turn, not the one you read.
///   • The agent going back to work clears the badge.
///   • Otherwise the badge keeps its previous state.
///
/// (The minimap's `awaitingPaneIDs` is the OTHER signal — raw "is awaiting
/// right now", no seen-gating — and deliberately doesn't go through this law.)
enum AttentionLaw {
    struct Verdict: Equatable {
        /// Whether the unread light is on after this pass.
        let lit: Bool
        /// New "read up to here" marker; nil = leave the recorded one as-is.
        let markSeen: UInt64?
    }

    static func verdict(
        wasLit: Bool,
        viewing: Bool,
        awaitingUser: Bool,
        fileSize: UInt64,
        seenSize: UInt64?
    ) -> Verdict {
        if viewing {
            return Verdict(lit: false, markSeen: fileSize)
        }
        if awaitingUser {
            if fileSize > (seenSize ?? 0) {
                return Verdict(lit: true, markSeen: nil)    // a new turn you haven't seen
            }
            return Verdict(lit: wasLit, markSeen: nil)      // the turn you already read
        }
        return Verdict(lit: false, markSeen: nil)           // back to working
    }
}
