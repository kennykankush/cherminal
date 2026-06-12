import Foundation

/// The conversation's live pulse, read straight from the session file's tail:
/// the agent's current plan (Claude `TodoWrite` / Codex `update_plan`) and the
/// last real exchange (your last prompt, the agent's last utterance). This is
/// what makes the inspector answer "what is this agent doing and where did we
/// leave off" at a glance — observe-externally, same file the turn light and
/// usage gauge already read, zero injection.
///
/// Shapes verified against real session files (2026-06):
///  - Claude: assistant records carry `message.content[]` blocks; a TodoWrite
///    call is `{"type":"tool_use","name":"TodoWrite","input":{"todos":[
///    {"content","activeForm","status"}]}}`. User records' content is a string
///    or blocks (tool_result echoes and injected command/system noise are not
///    real prompts). Sidechains live in separate files — never seen here.
///  - Codex: `payload.type` records — `user_message`/`agent_message` carry
///    `message` strings; `update_plan` is a function_call whose `arguments`
///    is a JSON *string* decoding to `{plan:[{step,status}]}`; `task_complete`
///    carries `last_agent_message` (the turn's final utterance).
enum SessionPulse {

    struct Todo: Equatable, Sendable {
        enum Status: String, Sendable {
            case pending, inProgress = "in_progress", completed
        }
        let text: String
        let status: Status
    }

    struct Pulse: Equatable, Sendable {
        var todos: [Todo] = []
        var lastUserText: String?
        var lastAssistantText: String?
        var isEmpty: Bool { todos.isEmpty && lastUserText == nil && lastAssistantText == nil }
        var todosDone: Int { todos.filter { $0.status == .completed }.count }
    }

    /// Generous tail: a single tool-result line can be hundreds of KB, and the
    /// last plan update + real exchange must land inside the window.
    static let tailBytes = 768 * 1024
    /// Snippets are glance material, not transcripts.
    static let snippetLimit = 280

    /// Bounded tail read + parse. nil for non-agent conversations or an
    /// unreadable file (a shell pane has no pulse).
    static func read(sessionFile: URL, agent: AgentKind) -> Pulse? {
        guard agent == .claudeCode || agent == .codex,
              let fh = try? FileHandle(forReadingFrom: sessionFile) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        return parse(tail: data, agent: agent)
    }

    /// Pure and unit-tested. Forward scan — later records overwrite earlier,
    /// so the tail's last word wins. A leading partial line (the tail buffer
    /// starts mid-record) simply fails JSON parsing and is skipped. Byte-level
    /// prefilters keep fat tool-result lines from ever reaching the JSON
    /// parser.
    static func parse(tail: Data, agent: AgentKind) -> Pulse {
        var pulse = Pulse()
        let newline = UInt8(ascii: "\n")
        for line in tail.split(separator: newline, omittingEmptySubsequences: true) {
            switch agent {
            case .claudeCode: ingestClaude(line, into: &pulse)
            case .codex:      ingestCodex(line, into: &pulse)
            default:          return pulse
            }
        }
        return pulse
    }

    // MARK: - Claude

    private static let mClaudeUser      = Data(#""type":"user""#.utf8)
    private static let mClaudeAssistant = Data(#""type":"assistant""#.utf8)
    private static let mTodoWrite       = Data(#""name":"TodoWrite""#.utf8)

    private static func ingestClaude(_ line: Data, into pulse: inout Pulse) {
        let isUser = line.range(of: mClaudeUser) != nil
        let isAssistant = line.range(of: mClaudeAssistant) != nil
        let hasTodos = line.range(of: mTodoWrite) != nil
        guard isUser || isAssistant || hasTodos else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String,
              let message = obj["message"] as? [String: Any] else { return }

        switch type {
        case "assistant":
            guard let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = clean(block["text"] as? String) {
                        pulse.lastAssistantText = text
                    }
                case "tool_use" where (block["name"] as? String) == "TodoWrite":
                    if let input = block["input"] as? [String: Any],
                       let todos = parseTodos(input["todos"], textKey: "content") {
                        pulse.todos = todos
                    }
                default:
                    break
                }
            }
        case "user":
            guard let content = message["content"] else { return }
            // tool_result echoes are the agent feeding itself, not you typing.
            if let blocks = content as? [[String: Any]],
               blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return }
            var raw: String?
            if let s = content as? String {
                raw = s
            } else if let blocks = content as? [[String: Any]] {
                raw = blocks.first { ($0["type"] as? String) == "text" }?["text"] as? String
            }
            if let text = clean(raw), !isInjectedNoise(text) {
                pulse.lastUserText = text
            }
        default:
            break
        }
    }

    // MARK: - Codex

    private static let mUserMessage  = Data(#""type":"user_message""#.utf8)
    private static let mAgentMessage = Data(#""type":"agent_message""#.utf8)
    private static let mUpdatePlan   = Data(#""name":"update_plan""#.utf8)
    private static let mTaskComplete = Data(#""type":"task_complete""#.utf8)

    private static func ingestCodex(_ line: Data, into pulse: inout Pulse) {
        guard line.range(of: mUserMessage) != nil
            || line.range(of: mAgentMessage) != nil
            || line.range(of: mUpdatePlan) != nil
            || line.range(of: mTaskComplete) != nil else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return }

        switch type {
        case "user_message":
            // Injected context blocks (<environment_context>…) aren't prompts.
            if let text = clean(payload["message"] as? String), !isInjectedNoise(text) {
                pulse.lastUserText = text
            }
        case "agent_message":
            if let text = clean(payload["message"] as? String) {
                pulse.lastAssistantText = text
            }
        case "task_complete":
            if let text = clean(payload["last_agent_message"] as? String) {
                pulse.lastAssistantText = text
            }
        case "function_call" where (payload["name"] as? String) == "update_plan":
            // arguments is a JSON-encoded STRING, not an object.
            guard let args = payload["arguments"] as? String,
                  let inner = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any],
                  let todos = parseTodos(inner["plan"], textKey: "step") else { return }
            pulse.todos = todos
        default:
            break
        }
    }

    // MARK: - Shared

    private static func parseTodos(_ any: Any?, textKey: String) -> [Todo]? {
        guard let rows = any as? [[String: Any]] else { return nil }
        let todos = rows.compactMap { row -> Todo? in
            guard let text = clean(row[textKey] as? String) else { return nil }
            let status = (row["status"] as? String).flatMap(Todo.Status.init(rawValue:)) ?? .pending
            return Todo(text: text, status: status)
        }
        return todos.isEmpty ? nil : todos
    }

    private static func clean(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return String(text.prefix(snippetLimit))
    }

    /// Harness-injected records that aren't the human typing.
    private static func isInjectedNoise(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("<command") || lowered.hasPrefix("<local-command")
            || lowered.hasPrefix("<system-reminder") || lowered.hasPrefix("<environment_context")
            || lowered.hasPrefix("<permissions") || lowered.hasPrefix("<user_instructions")
            || lowered.hasPrefix("<task-notification") || lowered.hasPrefix("<task-")
            || lowered.hasPrefix("caveat:") || text.hasPrefix("[Request interrupted")
    }
}
