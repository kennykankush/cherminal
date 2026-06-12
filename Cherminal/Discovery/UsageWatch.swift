import Foundation

/// ONE place that knows each agent's current account rate-limit state,
/// independent of which conversation the inspector happens to show. Fed by
/// the coordinator's reconcile tick (8s — throttled internally), it:
///
///   • serves freshened windows to the Details meters (claude's only source;
///     codex's account-level fallback)
///   • arbitrates the BURST flag through `BurstLaw` so a stale terminal
///     banner can't outlive the actual reset
///   • posts the proactive notifications: limit approaching (≥90%), limit
///     refreshed, burst began/lifted, context window ≥90%
///
/// Pure observation: the claude windows come from the already-throttled
/// `ClaudeRateLimits` actor; the codex windows from the newest rollout's
/// tail. No new network paths, no Keychain.
@MainActor
final class UsageWatch: ObservableObject {
    static let shared = UsageWatch()

    @Published private(set) var windowsByAgent: [AgentKind: [ConversationUsage.RateWindow]] = [:]
    /// Codex's in-file `rate_limit_reached_type` from the newest rollout.
    private(set) var codexReachedFlag = false

    private var lastCodexParse = Date.distantPast
    private let codexParseTTL: TimeInterval = 30
    /// Agents currently flagged as bursting — for begin/end notifications.
    private var bursting: Set<AgentKind> = []
    /// Per-conversation context-alert arming (UsageAlertLaw.contextGate).
    private var contextArmed: [String: Bool] = [:]

    /// Freshened (reset-expiry applied) windows for an agent. Claude's
    /// staleness is already wall-bounded by ClaudeRateLimits (empty when
    /// >15 min old); codex windows stay valid until their own resets pass —
    /// `freshen` zeroes anything whose reset is behind us.
    func windows(for agent: AgentKind) -> [ConversationUsage.RateWindow] {
        RateWindowLaw.freshen(windowsByAgent[agent] ?? [])
    }

    /// The burst arbitration the coordinator's banner scan delegates to.
    func isLimited(_ agent: AgentKind, textSeen: Bool) -> Bool {
        BurstLaw.isLimited(textSeen: textSeen,
                           reachedFlag: agent == .codex && codexReachedFlag,
                           windows: windowsByAgent[agent] ?? [])
    }

    /// Refresh both agents' windows. Called every reconcile tick; internally
    /// cheap (claude: 60s-cached actor; codex: 30s-throttled tail parse).
    func refresh(newestCodexFile: URL?) async {
        let claude = await ClaudeRateLimits.shared.windows()
        // Empty is authoritative for claude — the actor already keeps
        // last-good for 15 min, so an empty answer means "unknown", and the
        // meters must read absent, not frozen.
        apply(claude, for: .claudeCode, emptyIsAuthoritative: true)

        if let file = newestCodexFile,
           Date().timeIntervalSince(lastCodexParse) >= codexParseTTL {
            lastCodexParse = Date()
            let parsed = await Task.detached(priority: .utility) {
                ConversationUsageParser.parseCodex(sessionFile: file)
            }.value
            if let parsed {
                codexReachedFlag = parsed.limitReached
                // An empty tail is NOT authoritative here (windows may simply
                // sit earlier in the file than the tail window reaches).
                apply(parsed.rateWindows, for: .codex, emptyIsAuthoritative: false)
            }
        }
    }

    private func apply(_ fresh: [ConversationUsage.RateWindow],
                       for agent: AgentKind,
                       emptyIsAuthoritative: Bool) {
        let prev = windowsByAgent[agent] ?? []
        if fresh.isEmpty {
            if emptyIsAuthoritative, !prev.isEmpty { windowsByAgent[agent] = [] }
            return
        }
        for alert in UsageAlertLaw.alerts(previous: RateWindowLaw.freshen(prev),
                                          current: RateWindowLaw.freshen(fresh)) {
            FleetAlerts.notifyUsage(agent: agent, alert: alert)
        }
        if prev != fresh { windowsByAgent[agent] = fresh }
    }

    /// The coordinator reports the arbitrated burst set each tick; diffing it
    /// here yields the began/lifted notifications exactly once per episode.
    func reportBursting(_ set: Set<AgentKind>) {
        for agent in set.subtracting(bursting) {
            FleetAlerts.notifyBurst(agent, began: true,
                                    resetsAt: BurstLaw.bindingReset(windows(for: agent)))
        }
        for agent in bursting.subtracting(set) {
            FleetAlerts.notifyBurst(agent, began: false, resetsAt: nil)
        }
        bursting = set
    }

    /// The inspector's poll reports the active conversation's context fill;
    /// crossing 90% (hysteresis: re-arms below 75%) earns one notification.
    func reportContext(conversationID: String, agent: AgentKind, room: String, percent: Double) {
        let armed = contextArmed[conversationID] ?? true
        let (fire, next) = UsageAlertLaw.contextGate(armed: armed, percent: percent)
        contextArmed[conversationID] = next
        if fire { FleetAlerts.notifyContextHigh(agent: agent, room: room, percent: percent) }
    }
}
