import Testing
import Foundation
@testable import Cherminal

/// Locks down the head/tail summary extraction — the fiddliest parsing in the
/// app, and the first thing to silently break if Claude changes its JSONL.
struct SessionParserTests {

    @Test func extractsTitleTimestampsCwdAndCount() throws {
        let url = Fixtures.writeJSONL([
            #"{"type":"user","timestamp":"2026-05-01T10:00:00.000Z","cwd":"/Users/x/dev/foo","message":{"role":"user","content":"First real prompt"}}"#,
            #"{"type":"ai-title","aiTitle":"My Title"}"#,
            #"{"type":"assistant","timestamp":"2026-05-01T10:30:00.000Z","message":{"role":"assistant","content":"hi"}}"#,
            // Tool-result echo arrives as a synthetic "user" record — must NOT
            // count as a real user turn.
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"last-prompt","lastPrompt":"the last one","timestamp":"2026-05-01T11:00:00.000Z"}"#,
        ])

        let s = try SessionParser.summarize(file: url)
        #expect(s.aiTitle == "My Title")
        #expect(s.firstUserMessage == "First real prompt")
        #expect(s.lastPrompt == "the last one")
        #expect(s.cwd == "/Users/x/dev/foo")
        #expect(s.userMessageCount == 1)               // echo excluded
        #expect(s.firstTimestamp != nil)
        #expect(s.lastTimestamp != nil)
        #expect(s.firstTimestamp! < s.lastTimestamp!)
    }

    @Test func skipsCommandAndSystemNoiseForTitle() throws {
        let url = Fixtures.writeJSONL([
            #"{"type":"user","timestamp":"2026-05-01T10:00:00.000Z","message":{"role":"user","content":"<command-name>/foo</command-name>"}}"#,
            #"{"type":"user","timestamp":"2026-05-01T10:01:00.000Z","message":{"role":"user","content":"caveat: blah"}}"#,
            ##"{"type":"user","timestamp":"2026-05-01T10:02:00.000Z","message":{"role":"user","content":"# Actual question here"}}"##,
        ])
        let s = try SessionParser.summarize(file: url)
        // The first two are injected noise; the title is the third, with its
        // markdown header marker stripped.
        #expect(s.firstUserMessage == "Actual question here")
    }

    @Test func handlesFileWithoutTrailingNewline() throws {
        // Write a complete object but no trailing newline.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherminal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("x.jsonl")
        try #"{"type":"user","timestamp":"2026-05-01T10:00:00.000Z","message":{"role":"user","content":"only line"}}"#
            .data(using: .utf8)!.write(to: url)

        let s = try SessionParser.summarize(file: url)
        #expect(s.firstUserMessage == "only line")
        #expect(s.lastTimestamp != nil)
    }

    @Test func customTitleFromRenameWins() throws {
        // `/rename` writes a custom-title record; it must be captured and take
        // precedence over the auto ai-title.
        let url = Fixtures.writeJSONL([
            #"{"type":"user","timestamp":"2026-05-01T10:00:00.000Z","message":{"role":"user","content":"first prompt"}}"#,
            #"{"type":"ai-title","aiTitle":"Auto Title"}"#,
            #"{"type":"custom-title","customTitle":"My Renamed Session","sessionId":"x"}"#,
        ])
        let s = try SessionParser.summarize(file: url)
        #expect(s.customTitle == "My Renamed Session")
        #expect(s.aiTitle == "Auto Title")
    }

    @Test func emptyFileYieldsZeroLines() throws {
        let url = Fixtures.writeJSONL([])   // just a newline
        let s = try SessionParser.summarize(file: url)
        #expect(s.userMessageCount == 0)
        #expect(s.aiTitle == nil)
    }
}
