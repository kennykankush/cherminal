import Foundation

/// Laws for account usage-limit state — pure functions over `RateWindow`
/// snapshots, so staleness, burst arbitration, and notification crossings are
/// decided in ONE place and pinned by tests (house style: extract the law,
/// delegate, pin). The side-effecting watcher is `UsageWatch`.
enum RateWindowLaw {
    /// A window whose reset moment has passed describes the PREVIOUS cycle —
    /// showing its old % as live is the frozen-meter lie (the "CLAUDE BURST
    /// stays after reset" bug, 2026-06-13). Zero it and drop the stale
    /// countdown: the new cycle starts near 0 until fresher data arrives.
    static func freshen(_ windows: [ConversationUsage.RateWindow],
                        now: Date = Date()) -> [ConversationUsage.RateWindow] {
        windows.map { w in
            guard let resets = w.resetsAt, resets <= now else { return w }
            return .init(label: w.label, usedPercent: 0, resetsAt: nil,
                         detail: w.detail, windowMinutes: w.windowMinutes)
        }
    }
}

/// The deficit watch (CodexBar's pace model): compare actual usage to where
/// it WOULD be if the window drained evenly, and project depletion at the
/// current burn rate. "+9% in deficit" = burning faster than the window
/// refills; "in reserve" = headroom; `runsOutIn` non-nil = at this pace the
/// limit hits BEFORE the reset.
enum PaceLaw {
    struct Pace: Equatable {
        /// Where an even burn would be right now (0–100).
        let expectedPercent: Double
        /// actual − expected: positive = deficit, negative = reserve.
        let deltaPercent: Double
        /// Seconds until 100% at the current average rate — only when that
        /// lands BEFORE the reset (nil = lasts until reset).
        let runsOutIn: TimeInterval?
    }

    /// Pace deltas under this magnitude read as "on pace" — sub-2% is noise.
    static let onPaceBand = 2.0

    static func pace(for w: ConversationUsage.RateWindow, now: Date = Date()) -> Pace? {
        guard let resets = w.resetsAt,
              let minutes = w.windowMinutes, minutes > 0 else { return nil }
        let duration = TimeInterval(minutes) * 60
        let untilReset = resets.timeIntervalSince(now)
        // Expired or nonsensical (reset further out than the window is long).
        guard untilReset > 0, untilReset <= duration else { return nil }
        let elapsed = duration - untilReset
        // Too early in the window to project anything meaningful.
        guard elapsed >= 60 else { return nil }
        let expected = min(100, max(0, elapsed / duration * 100))
        let delta = w.usedPercent - expected
        var runsOutIn: TimeInterval?
        let rate = w.usedPercent / elapsed   // % per second, average so far
        if rate > 0 {
            let eta = (100 - w.usedPercent) / rate
            if eta < untilReset { runsOutIn = eta }
        }
        return Pace(expectedPercent: expected, deltaPercent: delta, runsOutIn: runsOutIn)
    }
}

/// Is an agent actually at its usage limit right now? Three signals, ranked:
///   1. codex's in-file `rate_limit_reached_type` (authoritative — but only
///      while its binding reset is still ahead; the caller freshens first)
///   2. an account window pegged at ~100%
///   3. the terminal banner (BurstDetector) — necessary for claude model
///      limits the API may not report, but STALE the moment the limit resets
///      while the banner still sits in the viewport. With account data in
///      hand, a banner nothing corroborates is treated as stale.
enum BurstLaw {
    static func isLimited(textSeen: Bool,
                          reachedFlag: Bool,
                          windows: [ConversationUsage.RateWindow],
                          now: Date = Date()) -> Bool {
        let live = RateWindowLaw.freshen(windows, now: now)
        if reachedFlag { return true }
        if live.contains(where: { $0.usedPercent >= 99.5 }) { return true }
        guard textSeen else { return false }
        guard !live.isEmpty else { return true }   // no data — trust the banner
        return live.contains { $0.usedPercent >= 95 }
    }

    /// When the current burst lifts: the reset of the most-exhausted window.
    static func bindingReset(_ windows: [ConversationUsage.RateWindow],
                             now: Date = Date()) -> Date? {
        var best: ConversationUsage.RateWindow?
        for w in windows {
            guard w.usedPercent >= 95, let resets = w.resetsAt, resets > now else { continue }
            if best == nil || w.usedPercent > best!.usedPercent { best = w }
        }
        return best?.resetsAt
    }
}

/// Which notifications a windows-snapshot transition earns. Pure diff —
/// `UsageWatch` holds the snapshots and posts the banners.
enum UsageAlertLaw {
    /// Crossing UP through this fires "approaching" (the user's "10% away").
    static let approachPercent = 90.0
    /// A high window dropping below this reads as "the limit refreshed".
    static let refreshedBelowPercent = 50.0

    struct Alert: Equatable {
        enum Kind: Equatable { case approaching, refreshed }
        let kind: Kind
        let label: String        // "5h" / "Weekly" / "Opus" …
        let percent: Int         // current used %
        let resetsAt: Date?
    }

    /// Compare consecutive snapshots of the SAME agent's windows. Both sides
    /// must be freshened first; labels missing on either side produce nothing
    /// (no data ≠ a reset).
    static func alerts(previous: [ConversationUsage.RateWindow],
                       current: [ConversationUsage.RateWindow]) -> [Alert] {
        guard !previous.isEmpty, !current.isEmpty else { return [] }
        let prevByLabel = Dictionary(previous.map { ($0.label, $0) },
                                     uniquingKeysWith: { a, _ in a })
        var out: [Alert] = []
        for w in current {
            guard let p = prevByLabel[w.label] else { continue }
            if p.usedPercent < approachPercent, w.usedPercent >= approachPercent {
                out.append(Alert(kind: .approaching, label: w.label,
                                 percent: Int(w.usedPercent), resetsAt: w.resetsAt))
            }
            if p.usedPercent >= approachPercent, w.usedPercent < refreshedBelowPercent {
                out.append(Alert(kind: .refreshed, label: w.label,
                                 percent: Int(w.usedPercent), resetsAt: w.resetsAt))
            }
        }
        return out
    }

    /// Context-gauge hysteresis: fire once when crossing UP through 90% while
    /// armed; re-arm only after dropping below 75% (a compact / new session).
    /// Without the re-arm gap, a gauge hovering at 89–91% would spam.
    static func contextGate(armed: Bool, percent: Double) -> (fire: Bool, armed: Bool) {
        if armed && percent >= approachPercent { return (true, false) }
        if !armed && percent < 75 { return (false, true) }
        return (false, armed)
    }
}
