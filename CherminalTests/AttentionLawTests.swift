import Testing
import Foundation
@testable import Cherminal

/// The "your turn" unread-badge law — previously inline in the coordinator's
/// reconcile loop where no test could reach it.
struct AttentionLawTests {

    @Test func viewingClearsAndMarksRead() {
        let v = AttentionLaw.verdict(wasLit: true, viewing: true,
                                     awaitingUser: true, fileSize: 500, seenSize: 100)
        #expect(v == AttentionLaw.Verdict(lit: false, markSeen: 500))
    }

    @Test func newTurnLightsOnlyWhenFileGrewPastSeen() {
        // Grew past the read marker → a genuinely new turn → light.
        let fresh = AttentionLaw.verdict(wasLit: false, viewing: false,
                                         awaitingUser: true, fileSize: 600, seenSize: 500)
        #expect(fresh.lit)
        #expect(fresh.markSeen == nil)

        // The same turn you already read (size ≤ seen) → never re-lights…
        let reread = AttentionLaw.verdict(wasLit: false, viewing: false,
                                          awaitingUser: true, fileSize: 500, seenSize: 500)
        #expect(!reread.lit)

        // …but an ALREADY-lit badge stays lit until viewed or work resumes.
        let stillLit = AttentionLaw.verdict(wasLit: true, viewing: false,
                                            awaitingUser: true, fileSize: 500, seenSize: 500)
        #expect(stillLit.lit)
    }

    @Test func neverSeenMeansAnyCompletedTurnLights() {
        let v = AttentionLaw.verdict(wasLit: false, viewing: false,
                                     awaitingUser: true, fileSize: 1, seenSize: nil)
        #expect(v.lit)
    }

    @Test func backToWorkingClears() {
        let v = AttentionLaw.verdict(wasLit: true, viewing: false,
                                     awaitingUser: false, fileSize: 900, seenSize: 100)
        #expect(v == AttentionLaw.Verdict(lit: false, markSeen: nil))
    }
}
