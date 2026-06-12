import Testing
import Foundation
@testable import Cherminal

struct UsageAccumulatorTests {

    private func assistant(id: String, req: String, input: Int, output: Int,
                           cacheRead: Int = 0, cacheCreate: Int = 0,
                           model: String = "claude-opus-4-7[1m]") -> String {
        #"{"type":"assistant","requestId":"\#(req)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate)}}}"#
    }
    private func user(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    @Test func totalsDedupByKeyAndCountsMessages() {
        let url = Fixtures.writeJSONL([
            user("q1"),
            assistant(id: "m1", req: "r1", input: 100, output: 10, cacheRead: 5, cacheCreate: 2),
            // Same message id/requestId streamed again with a larger output —
            // must be deduped to the max, not summed.
            assistant(id: "m1", req: "r1", input: 100, output: 25, cacheRead: 5, cacheCreate: 2),
            user("q2"),
            assistant(id: "m2", req: "r2", input: 200, output: 5, cacheRead: 50, cacheCreate: 0),
        ])

        let u = ConversationUsageParser.parse(sessionFile: url)
        #expect(u != nil)
        #expect(u?.totalInputTokens == 300)        // 100 + 200
        #expect(u?.totalOutputTokens == 30)        // 25 (max, not 10+25) + 5
        #expect(u?.cacheReadTokens == 55)          // 5 + 50
        #expect(u?.cacheCreateTokens == 2)         // 2 + 0
        #expect(u?.messageCount == 2)              // two real user turns
        // Latest turn footprint, captured atomically from m2: 200 + 50 + 0 + 5.
        // (cacheCreate is m2's actual 0, not m1's stale 2 — see fold().)
        #expect(u?.contextUsedTokens == 255)
        #expect(u?.contextWindowTokens == 1_000_000)   // [1m] model
        // Claude Code's own gauge denominator: window − 20k output reserve −
        // 13k auto-compact buffer (extracted from the installed binary).
        #expect(u?.contextBudgetTokens == 967_000)
        #expect(u?.contextBudgetUsedTokens == 255)
    }

    @Test func incrementalIngestDoesNotDoubleCount() {
        let acc = ClaudeUsageAccumulator()
        let url = Fixtures.writeJSONL([
            user("q1"),
            assistant(id: "m1", req: "r1", input: 100, output: 10),
        ])
        let first = acc.ingest(file: url)
        #expect(first?.totalOutputTokens == 10)
        #expect(first?.messageCount == 1)

        // The agent extends the live session — only the new bytes should be
        // folded in. If the offset were ignored, q1 would be re-counted.
        Fixtures.append([
            user("q2"),
            assistant(id: "m2", req: "r2", input: 200, output: 5),
        ], to: url)

        let second = acc.ingest(file: url)
        #expect(second?.totalOutputTokens == 15)   // 10 + 5, not 20
        #expect(second?.messageCount == 2)         // 1 + 1, not 3
    }

    @Test func resetsWhenFileTruncatedOrReplaced() throws {
        let acc = ClaudeUsageAccumulator()
        let url = Fixtures.writeJSONL([
            user("q1"), user("q2"), user("q3"),
            assistant(id: "m1", req: "r1", input: 100, output: 100),
        ])
        _ = acc.ingest(file: url)

        // Replace with a shorter file (size < prior offset) — accumulator must
        // start over, not keep stale totals.
        try (user("fresh") + "\n" + assistant(id: "z", req: "z", input: 9, output: 7) + "\n")
            .data(using: .utf8)!.write(to: url)

        let after = acc.ingest(file: url)
        #expect(after?.totalOutputTokens == 7)
        #expect(after?.messageCount == 1)
    }

    @Test func returnsNilForFileWithNoUsage() {
        let url = Fixtures.writeJSONL([user("just chatting"), user("no assistant rows")])
        #expect(ConversationUsageParser.parse(sessionFile: url) == nil)
    }
}

struct UsageMathTests {

    private func usage(used: Int, window: Int, cacheRead: Int = 0, input: Int = 0,
                       model: String? = nil) -> ConversationUsage {
        ConversationUsage(
            model: model,
            contextUsedTokens: used,
            contextWindowTokens: window,
            totalInputTokens: input,
            totalOutputTokens: 0,
            cacheReadTokens: cacheRead,
            cacheCreateTokens: 0
        )
    }

    @Test func contextPercentClampsAt100() {
        #expect(usage(used: 50_000, window: 100_000).contextUsedPercent == 50)
        #expect(usage(used: 150_000, window: 100_000).contextUsedPercent == 100)
        #expect(usage(used: 10, window: 0).contextUsedPercent == 0)   // no div-by-zero
    }

    @Test func cacheHitPercent() {
        #expect(usage(used: 0, window: 1, cacheRead: 90, input: 10).cacheHitPercent == 90)
        #expect(usage(used: 0, window: 1).cacheHitPercent == 0)
    }

    @Test func modelDisplayName() {
        #expect(usage(used: 0, window: 1, model: "claude-opus-4-7[1m]").modelDisplayName == "Opus 4.7 (1M)")
        #expect(usage(used: 0, window: 1, model: "claude-sonnet-4-6").modelDisplayName == "Sonnet 4.6")
        #expect(usage(used: 0, window: 1, model: nil).modelDisplayName == nil)
        #expect(usage(used: 0, window: 1, model: "").modelDisplayName == nil)
    }
}
