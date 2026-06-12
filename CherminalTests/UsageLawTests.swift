import Testing
import Foundation
@testable import Cherminal

/// Pins the usage-limit laws: window freshness, burst arbitration, alert
/// crossings, the context-fill gate, and the agent-parity context budgets.
struct UsageLawTests {

    private func window(_ label: String, _ pct: Double,
                        resetsIn: TimeInterval? = nil,
                        now: Date = .init(timeIntervalSince1970: 1_000_000)) -> ConversationUsage.RateWindow {
        .init(label: label, usedPercent: pct,
              resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Context budgets (agent-parity math)

    @Test func claudeBudgetMirrorsAutoCompactThreshold() {
        // 1M window → 980k effective − 13k buffer = 967k threshold. At 590.2k
        // used, claude shows 39% left; the gauge must agree (61% full), where
        // the raw-window math said 59% — the user's observed 3–4% gap.
        let b = ContextBudgetLaw.claude(window: 1_000_000, used: 590_200)
        #expect(b.budget == 967_000)
        let pctLeft = Double(b.budget - b.used) / Double(b.budget) * 100
        #expect(abs(pctLeft - 38.97) < 0.05)

        #expect(ContextBudgetLaw.claude(window: 200_000, used: 0).budget == 167_000)
    }

    @Test func codexBudgetSubtractsBaselineFromBothSides() {
        let b = ContextBudgetLaw.codex(window: 258_400, used: 123_359)
        #expect(b.budget == 246_400)
        #expect(b.used == 111_359)
        // Tiny sessions can sit under the baseline — never negative.
        #expect(ContextBudgetLaw.codex(window: 256_000, used: 5_000).used == 0)
    }

    // MARK: - Freshness

    @Test func freshenZeroesExpiredWindows() {
        let windows = [
            window("5h", 100, resetsIn: -60),       // reset already passed
            window("Weekly", 34, resetsIn: 3_600),  // still running
            window("Extra", 27),                    // no reset (spend meter)
        ]
        let fresh = RateWindowLaw.freshen(windows, now: now)
        #expect(fresh[0].usedPercent == 0)
        #expect(fresh[0].resetsAt == nil)
        #expect(fresh[1].usedPercent == 34)
        #expect(fresh[2].usedPercent == 27)
    }

    // MARK: - Burst arbitration

    @Test func burstClearsWhenResetPassesDespiteVisibleBanner() {
        // The exact stale-banner bug: limit text still in the viewport, but
        // the 5h window's reset has passed → not limited anymore.
        let stale = [window("5h", 100, resetsIn: -120), window("Weekly", 40, resetsIn: 86_400)]
        #expect(!BurstLaw.isLimited(textSeen: true, reachedFlag: false, windows: stale, now: now))

        // Same banner while the window is genuinely pegged → limited.
        let pegged = [window("5h", 100, resetsIn: 3_600)]
        #expect(BurstLaw.isLimited(textSeen: true, reachedFlag: false, windows: pegged, now: now))
    }

    @Test func burstWithoutDataTrustsTheBanner() {
        #expect(BurstLaw.isLimited(textSeen: true, reachedFlag: false, windows: [], now: now))
        #expect(!BurstLaw.isLimited(textSeen: false, reachedFlag: false, windows: [], now: now))
    }

    @Test func burstFiresFromWindowsAloneAndFromReachedFlag() {
        // Limit hit in another session — no banner in any pane here.
        let pegged = [window("5h", 99.8, resetsIn: 3_600)]
        #expect(BurstLaw.isLimited(textSeen: false, reachedFlag: false, windows: pegged, now: now))
        // Codex's authoritative flag wins outright.
        #expect(BurstLaw.isLimited(textSeen: false, reachedFlag: true, windows: [], now: now))
        // A banner contradicted by comfortable windows is stale → suppressed.
        let comfy = [window("5h", 22, resetsIn: 3_600), window("Weekly", 34, resetsIn: 86_400)]
        #expect(!BurstLaw.isLimited(textSeen: true, reachedFlag: false, windows: comfy, now: now))
    }

    @Test func bindingResetPicksTheMostExhaustedLiveWindow() {
        let windows = [
            window("Weekly", 96, resetsIn: 86_400),
            window("5h", 100, resetsIn: 1_800),
            window("Opus", 100, resetsIn: -60),   // already reset — not binding
        ]
        #expect(BurstLaw.bindingReset(windows, now: now) == now.addingTimeInterval(1_800))
        #expect(BurstLaw.bindingReset([window("5h", 50, resetsIn: 600)], now: now) == nil)
    }

    // MARK: - Alert crossings

    @Test func approachingFiresOnceOnUpwardCrossing() {
        let before = [window("5h", 85, resetsIn: 3_600), window("Weekly", 30, resetsIn: 86_400)]
        let after  = [window("5h", 92, resetsIn: 3_000), window("Weekly", 31, resetsIn: 86_000)]
        let alerts = UsageAlertLaw.alerts(previous: before, current: after)
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .approaching)
        #expect(alerts.first?.label == "5h")
        #expect(alerts.first?.percent == 92)

        // Already above: no re-fire.
        #expect(UsageAlertLaw.alerts(previous: after, current: after).isEmpty)
    }

    @Test func refreshedFiresWhenHighWindowDropsLow() {
        let before = [window("5h", 97, resetsIn: 300)]
        let after  = [window("5h", 2, resetsIn: 17_700)]
        let alerts = UsageAlertLaw.alerts(previous: before, current: after)
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .refreshed)

        // 90 → 60: below the approach line but not clearly refreshed — quiet.
        #expect(UsageAlertLaw.alerts(previous: [window("5h", 90)], current: [window("5h", 60)]).isEmpty)
        // Empty sides never alert (no data ≠ a reset).
        #expect(UsageAlertLaw.alerts(previous: [], current: after).isEmpty)
        #expect(UsageAlertLaw.alerts(previous: before, current: []).isEmpty)
    }

    // MARK: - Context gate (hysteresis)

    @Test func contextGateFiresOnceAndRearmsBelow75() {
        var (fire, armed) = UsageAlertLaw.contextGate(armed: true, percent: 91)
        #expect(fire && !armed)
        // Hovering high: silent.
        (fire, armed) = UsageAlertLaw.contextGate(armed: armed, percent: 93)
        #expect(!fire && !armed)
        // Dropping to 80 isn't enough to re-arm…
        (fire, armed) = UsageAlertLaw.contextGate(armed: armed, percent: 80)
        #expect(!fire && !armed)
        // …a compact down to 30 is.
        (fire, armed) = UsageAlertLaw.contextGate(armed: armed, percent: 30)
        #expect(!fire && armed)
        (fire, armed) = UsageAlertLaw.contextGate(armed: armed, percent: 90)
        #expect(fire && !armed)
    }
}
