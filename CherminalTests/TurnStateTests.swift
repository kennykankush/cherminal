import Testing
import Foundation
@testable import Cherminal

/// The "your turn" law, pinned with fixtures shaped like real session files
/// (verified against live ~/.claude and ~/.codex data, 2026-06).
struct TurnStateTests {

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnstate-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Claude

    @Test func claudeEndTurnLightsTheTurn() throws {
        let url = try write([
            #"{"type":"user","message":{"content":"do the thing"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TurnState.read(sessionFile: url, agent: .claudeCode).awaitingUser)
    }

    @Test func claudeToolUseAndStreamingPartialsReadAsWorking() throws {
        // Mid-task: the last assistant record is the orchestrator's tool_use
        // (this is also exactly what the main file shows while subagents run —
        // sidechain records live in separate files and can't appear here).
        let toolUse = try write([
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            #"{"type":"user","message":{"content":"next task"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: toolUse) }
        #expect(!TurnState.read(sessionFile: toolUse, agent: .claudeCode).awaitingUser)

        // A streaming partial carries stop_reason null → still working.
        let partial = try write([
            #"{"type":"assistant","message":{"stop_reason":null}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: partial) }
        #expect(!TurnState.read(sessionFile: partial, agent: .claudeCode).awaitingUser)
    }

    @Test func claudeTrailingUserRecordMeansAgentWillContinue() throws {
        let url = try write([
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!TurnState.read(sessionFile: url, agent: .claudeCode).awaitingUser)
    }

    @Test func claudeTrailingBookkeepingRecordsAreSkipped() throws {
        // mode / permission-mode / file-history-snapshot records trail real
        // turns (observed in live files) — they must not mask the boundary.
        let url = try write([
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            #"{"type":"file-history-snapshot","snapshot":{}}"#,
            #"{"type":"mode","mode":"default"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TurnState.read(sessionFile: url, agent: .claudeCode).awaitingUser)
    }

    // MARK: - Codex

    @Test func codexTaskCompleteAsLastLineLights() throws {
        // The observed real ordering: …, token_count, task_complete.
        let url = try write([
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TurnState.read(sessionFile: url, agent: .codex).awaitingUser)
    }

    @Test func codexBookkeepingTrailerAfterTaskCompleteStillLights() throws {
        // Robustness: if codex ever flips the order and writes token_count
        // AFTER task_complete, the backward scan skips it.
        let url = try write([
            #"{"payload":{"type":"task_complete"}}"#,
            #"{"payload":{"type":"token_count","info":{}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TurnState.read(sessionFile: url, agent: .codex).awaitingUser)
    }

    @Test func codexNewTurnActivityReadsAsWorking() throws {
        // A user message (or any substantive record) after the previous turn's
        // task_complete means a new turn is underway.
        let url = try write([
            #"{"payload":{"type":"task_complete"}}"#,
            #"{"payload":{"type":"user_message","message":"next"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!TurnState.read(sessionFile: url, agent: .codex).awaitingUser)
    }

    @Test func unreadableFileReadsAsNotAwaiting() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")
        let reading = TurnState.read(sessionFile: missing, agent: .claudeCode)
        #expect(!reading.awaitingUser)
        #expect(reading.size == 0)
    }
}

/// The incremental watcher must recognize EXACTLY what the full scanners
/// enumerate — getting this wrong invents phantom conversations (subagent
/// sidechain files are .jsonl under the claude root!).
struct SessionPathsTests {
    private let claude = "/Users/me/.claude/projects/"
    private let codex = "/Users/me/.codex/sessions/"

    @Test func recognizesRealSessionFiles() {
        #expect(SessionPaths.classify("\(claude)-Users-me-dev-foo/abc-123.jsonl",
                                      claudeRoot: claude, codexRoot: codex) == .claudeSession)
        #expect(SessionPaths.classify("\(codex)2026/06/09/rollout-2026-06-09-abc.jsonl",
                                      claudeRoot: claude, codexRoot: codex) == .codexRollout)
    }

    @Test func ignoresSidechainAndNoiseFiles() {
        // Subagent sidechains: deeper than <room>/<id>.jsonl — NOT sessions.
        #expect(SessionPaths.classify("\(claude)-Users-me-dev-foo/abc/subagents/agent-1.jsonl",
                                      claudeRoot: claude, codexRoot: codex) == .ignored)
        // Directories and non-rollout files under codex.
        #expect(SessionPaths.classify("\(codex)2026/06/09",
                                      claudeRoot: claude, codexRoot: codex) == .ignored)
        #expect(SessionPaths.classify("\(codex)2026/06/09/notes.jsonl",
                                      claudeRoot: claude, codexRoot: codex) == .ignored)
        // A project dir itself.
        #expect(SessionPaths.classify("\(claude)-Users-me-dev-foo",
                                      claudeRoot: claude, codexRoot: codex) == .ignored)
        // Unrelated paths.
        #expect(SessionPaths.classify("/tmp/whatever.jsonl",
                                      claudeRoot: claude, codexRoot: codex) == .ignored)
    }

    @Test func watchedRootMeansFullRescan() {
        #expect(SessionPaths.classify(String(claude.dropLast()),
                                      claudeRoot: claude, codexRoot: codex) == .fullRescan)
        #expect(SessionPaths.classify(codex,
                                      claudeRoot: claude, codexRoot: codex) == .fullRescan)
    }
}
