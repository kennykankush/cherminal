import Foundation
import Security

/// Fetches Claude's account-wide 5-hour and weekly (7-day) rate-limit windows
/// from Anthropic's OAuth usage endpoint (the only source for them — unlike
/// token usage, they aren't in the session JSONL). The one place Cherminal
/// reaches the network/Keychain, deliberately, to show the same 5H/7D meters
/// the dashboards do.
///
/// Keychain-prompt avoidance (the CodexBar approach — source diversification +
/// caching, since "Always Allow" doesn't stick for ad-hoc-signed builds):
///   token resolution = in-memory cache → our own cache file → the plaintext
///   ~/.claude/.credentials.json → Keychain (last resort, the only prompting
///   path). Once read, the token is cached to ~/.cherminal/claude-oauth.json
///   (0600) so future polls and launches read our file, not the Keychain —
///   we only re-touch the Keychain when the token is missing/expired.
actor ClaudeRateLimits {
    static let shared = ClaudeRateLimits()

    private var cachedWindows: [ConversationUsage.RateWindow] = []
    private var lastFetch = Date.distantPast
    private var lastSuccess = Date.distantPast
    private let windowTTL: TimeInterval = 60
    /// How long last-good values may stand in for failed refreshes. Beyond
    /// this the meters HIDE rather than show hours-old numbers as live — a
    /// 429 storm or a revoked token must read as "unknown", not as a frozen
    /// 85% (the stuck-meter bug, 2026-06-11).
    private let staleAfter: TimeInterval = 15 * 60

    private var token: (value: String, expiresAt: Date)?
    private let tokenCacheURL = URL(fileURLWithPath:
        (NSHomeDirectory() as NSString).appendingPathComponent(".cherminal/claude-oauth.json"))

    /// Cached windows, refreshed at most once a minute. Empty if no token /
    /// offline / plan doesn't report limits / values too stale to trust.
    func windows() async -> [ConversationUsage.RateWindow] {
        // Throttle every fetch attempt — including empty/failed ones — so an
        // account that legitimately reports no windows (or a persistent non-200)
        // can't turn this into an unthrottled 8s-per-tab poll. Stamp lastFetch
        // *before* the await so a concurrent caller also short-circuits, and keep
        // the last-good windows on an empty/failed result (bounded by staleAfter).
        if Date().timeIntervalSince(lastFetch) < windowTTL { return current() }
        lastFetch = Date()
        let fresh = await fetch()
        if !fresh.isEmpty {
            cachedWindows = fresh
            lastSuccess = Date()
        }
        return current()
    }

    private func current() -> [ConversationUsage.RateWindow] {
        Date().timeIntervalSince(lastSuccess) < staleAfter ? cachedWindows : []
    }

    // MARK: - Fetch

    private func fetch() async -> [ConversationUsage.RateWindow] {
        guard let tok = currentToken() else { return [] }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("cherminal/0.1 (claude-code/2.1)", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return [] }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { invalidateToken() }   // stale token → re-read source next time
        guard code == 200 else { return [] }
        return Self.parseUsageResponse(data)
    }

    /// Decode the usage payload into meters. Static + internal so the real
    /// captured response shape is pinned by tests. Besides the 5h/weekly
    /// windows, accounts on the extra-usage credits model (observed 2026-06)
    /// report `extra_usage` — the live spend meter ("$27.63 of $100") that is
    /// often the number that's actually moving while 5h sits at 0.
    static func parseUsageResponse(_ data: Data) -> [ConversationUsage.RateWindow] {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return [] }
        var out: [ConversationUsage.RateWindow] = []
        // Window lengths are fixed by kind (codex reports its own in-file;
        // claude's API doesn't, but the kinds define them) — PaceLaw needs
        // them for the deficit/reserve watch.
        if let w = usage.five_hour, let pct = w.utilization {
            out.append(.init(label: "5h", usedPercent: pct, resetsAt: isoDate(w.resets_at),
                             windowMinutes: 300))
        }
        if let w = usage.seven_day, let pct = w.utilization {
            out.append(.init(label: "Weekly", usedPercent: pct, resetsAt: isoDate(w.resets_at),
                             windowMinutes: 10_080))
        }
        // Model-scoped weekly windows (Max plans report these; shape pinned
        // from a real payload). They matter twice: the meters, and BurstLaw —
        // an "Opus limit" burst is confirmed/cleared by seven_day_opus, not
        // by the generic windows above. DORMANT ones (0% and no reset
        // running) stay hidden — a permanent "Sonnet 0%" meter is clutter.
        if let w = usage.seven_day_opus, let pct = w.utilization,
           pct > 0 || w.resets_at != nil {
            out.append(.init(label: "Opus", usedPercent: pct, resetsAt: isoDate(w.resets_at),
                             windowMinutes: 10_080))
        }
        if let w = usage.seven_day_sonnet, let pct = w.utilization,
           pct > 0 || w.resets_at != nil {
            out.append(.init(label: "Sonnet", usedPercent: pct, resetsAt: isoDate(w.resets_at),
                             windowMinutes: 10_080))
        }
        if let e = usage.extra_usage, e.is_enabled == true, let pct = e.utilization {
            var detail: String?
            if let used = e.used_credits, let limit = e.monthly_limit, limit > 0 {
                detail = String(format: "$%.2f of $%.0f", used / 100, limit / 100)
            }
            out.append(.init(label: "Extra", usedPercent: pct, resetsAt: nil, detail: detail))
        }
        return out
    }

    /// Parse an ISO8601 timestamp, tolerating fractional seconds (the OAuth usage
    /// endpoint includes them) — the same fractional-then-plain fallback the rest
    /// of Discovery uses (CodexSessionScanner, SessionParser).
    private static func isoDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: str) { return d }
        return ISO8601DateFormatter().date(from: str)
    }

    private struct UsageResponse: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
        let extra_usage: Extra?
        struct Window: Decodable { let utilization: Double?; let resets_at: String? }
        struct Extra: Decodable {
            let is_enabled: Bool?
            let utilization: Double?
            let used_credits: Double?     // cents
            let monthly_limit: Double?    // cents
        }
    }

    // MARK: - Token resolution (cache → file → Keychain)

    /// A usable (non-expired) access token, from the cheapest source available.
    private func currentToken() -> String? {
        // 1. In-memory (this launch).
        if let t = token, t.expiresAt > Date().addingTimeInterval(60) { return t.value }
        // 2. Our own cache file (survives launches — no prompt to read it).
        if let t = readTokenFile(tokenCacheURL), t.expiresAt > Date().addingTimeInterval(60) {
            token = t; return t.value
        }
        // 3. Claude's plaintext creds file, if present (no prompt). Gate on
        //    expiry like the cache-file path above — without this a stale token
        //    here is re-read every poll and 401s forever (we can't delete
        //    Claude's own file, so skipping it lets us fall through to Keychain).
        let credsFile = URL(fileURLWithPath:
            (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json"))
        if let t = readTokenFile(credsFile), t.expiresAt > Date().addingTimeInterval(60) {
            token = t; cacheToken(t); return t.value
        }
        // 4. Keychain — the only prompting path; we land here rarely (token
        //    missing or expired), not on every poll.
        if let t = readTokenFromKeychain() {
            token = t; cacheToken(t); return t.value
        }
        return nil
    }

    private func invalidateToken() {
        token = nil
        try? FileManager.default.removeItem(at: tokenCacheURL)
    }

    private func cacheToken(_ t: (value: String, expiresAt: Date)) {
        let dir = tokenCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = ["accessToken": t.value, "expiresAt": t.expiresAt.timeIntervalSince1970 * 1000]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: tokenCacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenCacheURL.path)
    }

    /// Parse `{accessToken,expiresAt}` or `{claudeAiOauth:{accessToken,expiresAt}}`
    /// (expiresAt is epoch milliseconds). Far-future expiry if absent.
    private func readTokenFile(_ url: URL) -> (value: String, expiresAt: Date)? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseToken(obj)
    }

    private func readTokenFromKeychain() -> (value: String, expiresAt: Date)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseToken(obj)
    }

    private func parseToken(_ obj: [String: Any]) -> (value: String, expiresAt: Date)? {
        let node = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let value = (node["accessToken"] as? String) ?? (node["access_token"] as? String) else { return nil }
        let ms = (node["expiresAt"] as? Double) ?? (node["expires_at"] as? Double) ?? 0
        let expiresAt = ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : Date.distantFuture
        return (value, expiresAt)
    }
}
