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
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50},"last_token_usage":{"total_tokens":120000},"model_context_window":256000},"rate_limits":{"primary":{"used_percent":42.5,"resets_at":1760000000},"secondary":{"used_percent":10,"resets_at":1760600000}}}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let usage = ConversationUsageParser.parseCodex(sessionFile: url)
        #expect(usage?.contextUsedTokens == 120_000)
        #expect(usage?.contextWindowTokens == 256_000)
        #expect(usage?.totalInputTokens == 200)        // 1000 input − 800 cached = fresh
        #expect(usage?.cacheReadTokens == 800)
        #expect(usage?.totalOutputTokens == 50)
        #expect(usage?.rateWindows.map(\.label) == ["5h", "Weekly"])
        #expect(usage?.rateWindows.first?.usedPercent == 42.5)
    }

    @Test func rolloutWithoutTokenCountYieldsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chm-codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"payload":{"type":"agent_message"}}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(ConversationUsageParser.parseCodex(sessionFile: url) == nil)
    }
}
