import Testing
import Foundation
@testable import Cherminal

/// SessionPulse — the inspector's "what is the agent doing / where did we
/// leave off" law. Fixtures mirror REAL session-file records (sampled
/// 2026-06): Claude TodoWrite tool_use blocks, Codex update_plan
/// function_calls (arguments is a JSON *string*), user/agent message shapes,
/// and the noise that must never read as a prompt.
struct SessionPulseTests {

    private func parse(_ lines: [String], agent: AgentKind) -> SessionPulse.Pulse {
        SessionPulse.parse(tail: Data(lines.joined(separator: "\n").utf8), agent: agent)
    }

    // MARK: - Claude

    @Test func claudePlanAndExchange() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"fix the login bug please"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"On it — reproducing first."},{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Reproduce the bug","activeForm":"Reproducing","status":"completed"},{"content":"Fix the root cause","activeForm":"Fixing","status":"in_progress"},{"content":"Add a regression test","activeForm":"Testing","status":"pending"}]}}]}}"#,
        ]
        let p = parse(lines, agent: .claudeCode)
        #expect(p.todos.count == 3)
        #expect(p.todos[0].status == .completed)
        #expect(p.todos[1] == .init(text: "Fix the root cause", status: .inProgress))
        #expect(p.todosDone == 1)
        #expect(p.lastUserText == "fix the login bug please")
        #expect(p.lastAssistantText == "On it — reproducing first.")
    }

    @Test func claudeLaterRecordsWin() {
        let lines = [
            #"{"type":"user","message":{"content":"first prompt"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Old plan","status":"pending"}]}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"second prompt"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"New plan","status":"in_progress"}]}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done — both fixed."}]}}"#,
        ]
        let p = parse(lines, agent: .claudeCode)
        #expect(p.todos == [.init(text: "New plan", status: .inProgress)])
        #expect(p.lastUserText == "second prompt")
        #expect(p.lastAssistantText == "Done — both fixed.")
    }

    @Test func claudeNoiseIsNotAPrompt() {
        let lines = [
            #"{"type":"user","message":{"content":"the real prompt"}}"#,
            // tool_result echo: the agent feeding itself.
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"file contents..."}]}}"#,
            // Injected command/system records.
            #"{"type":"user","message":{"content":"<command-name>/compact</command-name>"}}"#,
            #"{"type":"user","message":{"content":"<system-reminder>hook output</system-reminder>"}}"#,
            #"{"type":"user","message":{"content":"Caveat: the messages below were generated..."}}"#,
            #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
            // A pure tool_use assistant record must not blank the last text.
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
        ]
        let p = parse(lines, agent: .claudeCode)
        #expect(p.lastUserText == "the real prompt")
        #expect(p.lastAssistantText == nil)
    }

    @Test func claudeLeadingPartialLineIsSkipped() {
        let tail = Data((
            #"sage":{"content":[{"type":"text","text":"chopped mid-record"}]}}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"text","text":"intact"}]}}"#
        ).utf8)
        let p = SessionPulse.parse(tail: tail, agent: .claudeCode)
        #expect(p.lastAssistantText == "intact")
    }

    // MARK: - Codex

    @Test func codexPlanAndExchange() {
        let lines = [
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"build the watcher bridge"}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"explanation\":\"plan\",\"plan\":[{\"status\":\"completed\",\"step\":\"Confirm scope\"},{\"status\":\"in_progress\",\"step\":\"Define MVP\"},{\"status\":\"pending\",\"step\":\"Wire telegram\"}]}"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"agent_message","message":"Grounding in the actual repo shape first."}}"#,
        ]
        let p = parse(lines, agent: .codex)
        #expect(p.todos.count == 3)
        #expect(p.todos[1] == .init(text: "Define MVP", status: .inProgress))
        #expect(p.lastUserText == "build the watcher bridge")
        #expect(p.lastAssistantText == "Grounding in the actual repo shape first.")
    }

    @Test func codexTaskCompleteCarriesTheFinalWord() {
        let lines = [
            #"{"payload":{"type":"agent_message","message":"working on it"}}"#,
            #"{"payload":{"type":"token_count","info":null}}"#,
            #"{"payload":{"type":"task_complete","turn_id":"x","last_agent_message":"All three fixes are in."}}"#,
        ]
        let p = parse(lines, agent: .codex)
        #expect(p.lastAssistantText == "All three fixes are in.")
    }

    @Test func codexInjectedContextIsNotAPrompt() {
        let lines = [
            #"{"payload":{"type":"user_message","message":"real question"}}"#,
            #"{"payload":{"type":"user_message","message":"<environment_context>cwd...</environment_context>"}}"#,
            #"{"payload":{"type":"user_message","message":"<user_instructions>...</user_instructions>"}}"#,
        ]
        let p = parse(lines, agent: .codex)
        #expect(p.lastUserText == "real question")
    }

    // MARK: - Shared

    @Test func snippetsAreBoundedAndTrimmed() {
        let long = String(repeating: "x", count: 5_000)
        let lines = [#"{"type":"user","message":{"content":"  \n"# + long + #""}}"#]
        let p = parse(lines, agent: .claudeCode)
        #expect(p.lastUserText?.count == SessionPulse.snippetLimit)
        #expect(p.lastUserText?.hasPrefix("x") == true)   // leading whitespace trimmed
    }

    @Test func shellHasNoPulse() {
        #expect(SessionPulse.read(sessionFile: URL(fileURLWithPath: "/tmp"), agent: .shell) == nil)
        let p = parse([#"{"type":"user","message":{"content":"hi"}}"#], agent: .shell)
        #expect(p.isEmpty)
    }
}
