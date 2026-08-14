import Testing
import Foundation
@testable import Cherminal

/// Fixture tests for the scanner paths that had none: the codex rollout
/// parser, claude's compaction-chain detection, and codex usage extraction.
/// Fixtures mirror the real on-disk record shapes.
struct CodexScannerTests {

    private func writeRollout(_ lines: [String], name: String = "rollout-2026-06-10T01-00-00-fixture.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func summarizesRolloutMetaTimestampsAndPreviewFallback() throws {
        let url = try writeRollout([
            #"{"timestamp":"2026-06-10T01:00:00Z","type":"session_meta","payload":{"id":"sess-1","cwd":"/Users/x/dev/room","timestamp":"2026-06-10T01:00:00Z"}}"#,
            #"{"timestamp":"2026-06-10T01:00:05Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"fix the flaky tests please"}]}}"#,
            #"{"timestamp":"2026-06-10T01:02:00Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let convo = CodexSessionScanner.summarizeFile(url, titles: [:], cache: nil)
        #expect(convo?.id == "sess-1")
        #expect(convo?.agent == .codex)
        #expect(convo?.roomPath.path == "/Users/x/dev/room")
        // Title index empty → falls back to the first real user prompt.
        #expect(convo?.previewText == "fix the flaky tests please")
        // Last activity = the most recent timestamped record (the tail scan).
        #expect(convo?.lastActivityAt.timeIntervalSince1970 ?? 0
                > convo?.firstMessageAt?.timeIntervalSince1970 ?? .infinity - 1)
    }

    @Test func titleIndexWinsOverPromptFallback() throws {
        let url = try writeRollout([
            #"{"timestamp":"2026-06-10T01:00:00Z","type":"session_meta","payload":{"id":"sess-2","cwd":"/r","timestamp":"2026-06-10T01:00:00Z"}}"#,
            #"{"timestamp":"2026-06-10T01:00:05Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"raw prompt"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let convo = CodexSessionScanner.summarizeFile(url, titles: ["sess-2": "Named thread"], cache: nil)
        #expect(convo?.previewText == "Named thread")
    }

    @Test func nonRolloutFilesAndInjectedWrappersAreRejected() throws {
        // Wrong filename shape → not a rollout, nil.
        let notRollout = try writeRollout(
            [#"{"type":"session_meta","payload":{"id":"x","cwd":"/r"}}"#],
            name: "notes.jsonl")
        defer { try? FileManager.default.removeItem(at: notRollout.deletingLastPathComponent()) }
        #expect(CodexSessionScanner.summarizeFile(notRollout, titles: [:], cache: nil) == nil)

        // Injected wrapper blocks must not become the preview title.
        let wrapped = try writeRollout([
            #"{"timestamp":"2026-06-10T01:00:00Z","type":"session_meta","payload":{"id":"sess-3","cwd":"/r","timestamp":"2026-06-10T01:00:00Z"}}"#,
            #"{"timestamp":"2026-06-10T01:00:01Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"<environment_context>stuff</environment_context>"}]}}"#,
            #"{"timestamp":"2026-06-10T01:00:02Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"the real ask"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: wrapped.deletingLastPathComponent()) }
        #expect(CodexSessionScanner.summarizeFile(wrapped, titles: [:], cache: nil)?.previewText == "the real ask")
    }
}

struct ClaudeCompactionChainTests {

    /// Claude's compaction handoff: the new session's first user turn embeds
    /// the PARENT's `<uuid>.jsonl` path immediately followed by the
    /// "Continue the conversation…" phrase. Detection must link child → parent.
    @Test func compactionContinuationLinksToParent() throws {
        let parent = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let selfID = "11111111-2222-3333-4444-555555555555"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(selfID).jsonl")
        let handoff = "…/projects/x/\(parent).jsonl\\nContinue the conversation from where it left off"
        try ([
            #"{"type":"user","cwd":"/Users/x/dev/room","timestamp":"2026-06-10T01:00:00Z","message":{"content":"\#(handoff)"}}"#,
            #"{"type":"assistant","timestamp":"2026-06-10T01:00:10Z","message":{"stop_reason":"end_turn"}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let convo = ClaudeSessionScanner.summarizeFile(url, cache: nil)
        #expect(convo?.id == selfID)
        #expect(convo?.continuedFromID == parent)
        #expect(convo?.roomPath.path == "/Users/x/dev/room")   // in-file cwd wins
    }

    @Test func ordinarySessionHasNoContinuationLink() throws {
        let selfID = "99999999-8888-7777-6666-555555555555"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(selfID).jsonl")
        try ([
            #"{"type":"user","cwd":"/r","timestamp":"2026-06-10T01:00:00Z","message":{"content":"hello"}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(ClaudeSessionScanner.summarizeFile(url, cache: nil)?.continuedFromID == nil)
    }
}

struct CodexUsageTests {

    /// Codex's token_count record carries the full usage picture; the parser
    /// must split cached from fresh input and surface the rate windows.
    @Test func parsesTokenCountTotalsWindowAndRateLimits() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ([
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"agent_message"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50},"last_token_usage":{"total_tokens":120000},"model_context_window":256000},"rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1760000000},"secondary":{"used_percent":10,"window_minutes":10080,"resets_at":1760600000}}}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let usage = ConversationUsageParser.parseCodex(sessionFile: url)
        #expect(usage?.contextUsedTokens == 120_000)
        #expect(usage?.contextWindowTokens == 256_000)
        #expect(usage?.totalInputTokens == 200)        // 1000 input − 800 cached = fresh
        #expect(usage?.cacheReadTokens == 800)
        #expect(usage?.totalOutputTokens == 50)
        #expect(usage?.rateWindows.map(\.label) == ["5h", "Weekly"])
        #expect(usage?.rateWindows.first?.usedPercent == 42.5)
        // window_minutes feeds PaceLaw (the deficit watch).
        #expect(usage?.rateWindows.map(\.windowMinutes) == [300, 10_080])
        // Codex's own % math: 12k baseline off both sides (codex-rs
        // percent_of_context_window_remaining) — (120k−12k)/(256k−12k).
        #expect(usage?.contextBudgetTokens == 244_000)
        #expect(usage?.contextBudgetUsedTokens == 108_000)
        #expect(abs((usage?.contextUsedPercent ?? 0) - 108_000.0 / 244_000.0 * 100) < 0.01)
        // No rate_limit_reached_type in the record → not limited.
        #expect(usage?.limitReached == false)
    }

    /// `rate_limit_reached_type` is the authoritative "at the limit" flag —
    /// a string while limited, JSON null once it isn't.
    @Test func limitReachedFlagParses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ([
            #"{"payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":100,"resets_at":1760000000},"secondary":{"used_percent":55,"resets_at":1760600000},"rate_limit_reached_type":"primary"}}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let usage = ConversationUsageParser.parseCodex(sessionFile: url)
        #expect(usage?.limitReached == true)

        // Explicit null (the everyday shape) must read as NOT limited.
        try ([
            #"{"payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":30,"resets_at":1760000000},"secondary":{"used_percent":20,"resets_at":1760600000},"rate_limit_reached_type":null}}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(ConversationUsageParser.parseCodex(sessionFile: url)?.limitReached == false)
    }

    /// Codex moved its weekly limit into `primary` (window_minutes 10080) and
    /// leaves `secondary` null, so the label must come from the window's own
    /// duration — a positional "5h" would mislabel a 7-day meter.
    @Test func labelsRateWindowsFromTheirOwnDuration() throws {
        let url = Fixtures.writeJSONL([
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10},"last_token_usage":{"total_tokens":5},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":41,"window_minutes":10080,"resets_at":1787199675},"secondary":null}}}"#,
        ], name: "codex-weekly-primary")
        defer { Fixtures.remove(url) }

        let usage = ConversationUsageParser.parseCodex(sessionFile: url)
        #expect(usage?.rateWindows.map(\.label) == ["Weekly"])
        #expect(usage?.rateWindows.first?.usedPercent == 41)
    }

    /// Labels are the RateWindow id — two windows of the same duration must not
    /// produce two rows with the same identity.
    @Test func dropsDuplicateWindowLabels() throws {
        let url = Fixtures.writeJSONL([
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":5}},"rate_limits":{"primary":{"used_percent":41,"window_minutes":10080},"secondary":{"used_percent":12,"window_minutes":10080}}}}"#,
        ], name: "codex-dup-window")
        defer { Fixtures.remove(url) }
        #expect(ConversationUsageParser.parseCodex(sessionFile: url)?.rateWindows.map(\.label) == ["Weekly"])
    }

    @Test func windowLabelReadsMinutes() {
        #expect(ConversationUsageParser.windowLabel(minutes: 300) == "5h")
        #expect(ConversationUsageParser.windowLabel(minutes: 10080) == "Weekly")
        #expect(ConversationUsageParser.windowLabel(minutes: 1440) == "Daily")
        #expect(ConversationUsageParser.windowLabel(minutes: 4320) == "3d")
        #expect(ConversationUsageParser.windowLabel(minutes: 45) == "45m")
        #expect(ConversationUsageParser.windowLabel(minutes: 0) == nil)   // absent → caller's fallback
    }

    @Test func rolloutWithoutTokenCountYieldsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"payload":{"type":"agent_message"}}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(ConversationUsageParser.parseCodex(sessionFile: url) == nil)
    }

    /// The 2026-06 "premium" account shape: token_count records can carry
    /// info:null, and rate_limits with primary/secondary null. The parser must
    /// read info and rate_limits INDEPENDENTLY — the newest record with each
    /// wins — instead of requiring both on one record (which blanked the
    /// whole usage section).
    @Test func premiumShapeReadsInfoAndLimitsIndependently() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ([
            // Older record: real numbers + real windows.
            #"{"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":20},"last_token_usage":{"total_tokens":80000},"model_context_window":256000},"rate_limits":{"primary":{"used_percent":39,"resets_at":1779097471},"secondary":{"used_percent":14,"resets_at":1779576700}}}}"#,
            // Newest record: the premium shape — info null, windows null.
            #"{"payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false,"balance":"0"}}}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let usage = ConversationUsageParser.parseCodex(sessionFile: url)
        #expect(usage?.contextUsedTokens == 80_000)            // from the older info
        #expect(usage?.rateWindows.map(\.label) == ["5h", "Weekly"])  // from the older limits
        #expect(usage?.rateWindows.first?.usedPercent == 39)
    }

    /// info present but windows never populated (premium plans don't report
    /// 5h/weekly) — numbers still show, limits section just stays absent.
    @Test func premiumWithNumbersButNoWindows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (#"{"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5},"last_token_usage":{"total_tokens":1000},"model_context_window":256000},"rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"# + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let usage = ConversationUsageParser.parseCodex(sessionFile: url)
        #expect(usage?.contextUsedTokens == 1_000)
        #expect(usage?.rateWindows.isEmpty == true)
    }

    /// A tail that's ALL info:null but has live windows still shows the
    /// limits (zeroed gauge beats a blank pane).
    @Test func allNullInfoStillSurfacesWindows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (#"{"payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":62,"resets_at":1779097471},"secondary":{"used_percent":9,"resets_at":1779576700}}}}"# + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let usage = ConversationUsageParser.parseCodex(sessionFile: url)
        #expect(usage?.contextUsedTokens == 0)
        #expect(usage?.rateWindows.first?.usedPercent == 62)
    }
}

/// The Claude OAuth usage payload — pinned against a REAL captured response
/// (2026-06-11). The account runs Anthropic's extra-usage credits model:
/// five_hour sits at 0 while the spend meter is the number actually moving,
/// so `extra_usage` must surface as its own meter.
struct ClaudeUsageResponseTests {

    @Test func parsesRealResponseIncludingExtraUsage() {
        let json = #"{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":{"utilization":85.0,"resets_at":"2026-06-14T18:00:00.288459+00:00"},"seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":{"utilization":0.0,"resets_at":null},"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":2763.0,"utilization":27.63,"currency":"USD","disabled_reason":null}}"#
        let windows = ClaudeRateLimits.parseUsageResponse(Data(json.utf8))
        // seven_day_sonnet is present but DORMANT (0%, no reset) — hidden.
        #expect(windows.map(\.label) == ["5h", "Weekly", "Extra"])
        #expect(windows[0].usedPercent == 0.0)
        #expect(windows[1].usedPercent == 85.0)
        #expect(windows[1].resetsAt != nil)
        #expect(windows[2].usedPercent == 27.63)
        #expect(windows[2].detail == "$27.63 of $100")
    }

    /// Model-scoped weekly windows surface once they're actually tracking
    /// usage — the data BurstLaw needs to confirm/clear an "Opus limit" burst.
    @Test func activeOpusWindowSurfaces() {
        let json = #"{"five_hour":{"utilization":40.0,"resets_at":null},"seven_day_opus":{"utilization":97.5,"resets_at":"2026-06-14T18:00:00+00:00"}}"#
        let windows = ClaudeRateLimits.parseUsageResponse(Data(json.utf8))
        #expect(windows.map(\.label) == ["5h", "Opus"])
        #expect(windows[1].usedPercent == 97.5)
        #expect(windows[1].resetsAt != nil)
    }

    @Test func extraUsageHiddenWhenDisabledAndGarbageYieldsNothing() {
        let disabled = #"{"five_hour":{"utilization":5.0,"resets_at":null},"extra_usage":{"is_enabled":false,"utilization":0}}"#
        #expect(ClaudeRateLimits.parseUsageResponse(Data(disabled.utf8)).map(\.label) == ["5h"])
        #expect(ClaudeRateLimits.parseUsageResponse(Data("not json".utf8)).isEmpty)
    }
}
