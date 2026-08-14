import Foundation

/// Inspects a tab's foreground process to figure out which agent session it's
/// running, so a hand-launched `claude`/`codex` can be linked to its
/// conversation. Pure external observation: `lsof` only, no injection.
///
/// Two signals, because the agents behave differently:
///   • Codex holds its rollout JSONL open for appending, so its open-file path
///     is a precise link (matched back to the registry by `sessionFile.path`).
///   • Claude opens/appends/closes per write, so it never shows the file open.
///     But its process cwd is the room it's writing under, so we fall back to
///     the most-recently-active Claude conversation in that room.
///
/// Neither signal lands on the tab's foreground process when the agent ships a
/// launcher: the npm `codex` is a `#!/usr/bin/env node` shim that re-execs the
/// platform binary as a CHILD, so the tty's foreground process is `node` with
/// nothing open, while the child holds the rollout. We therefore probe each
/// foreground pid together with its descendants and fold the agent-looking one
/// back onto the pid the caller asked about. (Claude ships a single native
/// binary, so it was never affected — which is exactly why Claude tabs linked
/// and Codex tabs silently stayed bare shells.)
enum LiveSessionLinker {
    struct ProcessInfo: Sendable {
        let command: String
        let cwd: String?
        /// A session JSONL the process currently holds open (Codex).
        let openSessionFile: String?
        /// The session id from the process's argv (`claude --resume <id>` /
        /// `codex resume <id>`) — the exact, verified conversation it's running.
        let resumeID: String?
        /// The full argv line (ProcTable's ps sweep) — lets the ledger see
        /// flags like `--continue` that change which conversation is meant.
        let launchArgv: String?
        /// When the process started (ProcTable's etime) — the ledger refuses
        /// to link a process to a conversation last written before it existed.
        let startedAt: Date?

        init(command: String, cwd: String?, openSessionFile: String?,
             resumeID: String?, launchArgv: String? = nil, startedAt: Date? = nil) {
            self.command = command
            self.cwd = cwd
            self.openSessionFile = openSessionFile
            self.resumeID = resumeID
            self.launchArgv = launchArgv
            self.startedAt = startedAt
        }
    }

    /// Inspect `pids` (one batched lsof), each together with its descendants.
    /// `argvByPID` / `startedByPID` / `childrenByParent` — when the caller
    /// already holds a ProcTable snapshot — supply each pid's command line,
    /// start time, and the process tree so no second `ps` is spawned; without
    /// them we fall back to our own ps call (resume ids only) and probe the
    /// foreground pids alone.
    static func inspect(pids: [Int32],
                        argvByPID: [Int32: String]? = nil,
                        startedByPID: [Int32: Date]? = nil,
                        childrenByParent: [Int32: [Int32]]? = nil) -> [Int32: ProcessInfo] {
        guard !pids.isEmpty else { return [:] }
        let home = NSHomeDirectory()
        let roots = [home + "/.claude/projects/", home + "/.codex/sessions/"]
        let descendants = descendantsByRoot(pids: pids, childrenByParent: childrenByParent)
        let probePIDs = pids + descendants.values.flatMap { $0 }
        let list = probePIDs.map(String.init).joined(separator: ",")

        // +c 0: full command names. -Fpcfn: pid, command, fd, name fields — the
        // fd tells us which `n` is the cwd vs a regular open file.
        guard let raw = run("/usr/sbin/lsof", ["-p", list, "+c", "0", "-Fpcfn"]) else { return [:] }
        let probed = parse(raw, roots: roots)
        // Resume ids come from argv — lsof's command field is only the name.
        // This is the accurate session link for a resumed agent (vs. guessing by
        // room recency), and under a shim it lives on whichever process in the
        // chain actually got the `resume <id>` arguments.
        let resumed: [Int32: String]
        if let argvByPID {
            var out: [Int32: String] = [:]
            for pid in probePIDs {
                if let argv = argvByPID[pid], let id = parseResumeID(argv) { out[pid] = id }
            }
            resumed = out
        } else {
            resumed = resumeIDs(pids: probePIDs)
        }

        var info: [Int32: ProcessInfo] = [:]
        for pid in pids {
            info[pid] = resolve(root: pid, descendants: descendants[pid] ?? [],
                                probed: probed, resumed: resumed,
                                argvByPID: argvByPID, startedByPID: startedByPID)
        }
        return info
    }

    /// Fold a foreground process and its descendants into the one ProcessInfo
    /// the caller asked about. Pure, so the shim case is unit-testable without
    /// spawning lsof. nil when lsof reported nothing for the root.
    static func resolve(root: Int32,
                        descendants: [Int32],
                        probed: [Int32: ProcessInfo],
                        resumed: [Int32: String],
                        argvByPID: [Int32: String]? = nil,
                        startedByPID: [Int32: Date]? = nil) -> ProcessInfo? {
        guard let own = probed[root] else { return nil }
        var merged = own
        // Only look past the foreground process when it hasn't identified
        // itself — a real agent (or anything holding a session file) always wins
        // over its own children.
        if !identifiesAgent(own), let child = agentDescendant(descendants, in: probed) {
            merged = ProcessInfo(command: child.command,
                                 cwd: own.cwd ?? child.cwd,
                                 openSessionFile: child.openSessionFile,
                                 resumeID: nil)
        }
        // argv/start time stay ROOT-first: the shim's argv carries the same
        // flags the ledger reads (`--continue`), and its start time is the
        // earlier one — the moment the invocation began, which is what "was
        // this conversation written before the process existed?" means.
        let chain = [root] + descendants
        return ProcessInfo(command: merged.command,
                           cwd: merged.cwd,
                           openSessionFile: merged.openSessionFile,
                           resumeID: chain.compactMap { resumed[$0] }.first,
                           launchArgv: chain.compactMap { argvByPID?[$0] }.first,
                           startedAt: chain.compactMap { startedByPID?[$0] }.first)
    }

    /// Descendant pids of each root, breadth-first. Bounded on both axes so a
    /// chatty agent (one that spawns a tool subprocess per turn) can't grow the
    /// lsof argument list without limit — depth 2 covers the shim → binary hop
    /// with room to spare. Other roots are never traversed into, so one pane can
    /// never adopt the agent running in another.
    static func descendantsByRoot(pids: [Int32],
                                  childrenByParent: [Int32: [Int32]]?,
                                  maxDepth: Int = 2,
                                  maxPerRoot: Int = 8) -> [Int32: [Int32]] {
        guard let childrenByParent, !childrenByParent.isEmpty else { return [:] }
        let rootSet = Set(pids)
        var out: [Int32: [Int32]] = [:]
        for root in pids {
            var found: [Int32] = []
            var seen: Set<Int32> = [root]
            var frontier = (childrenByParent[root] ?? []).sorted()
            var depth = 1
            while !frontier.isEmpty, depth <= maxDepth, found.count < maxPerRoot {
                var next: [Int32] = []
                for pid in frontier {
                    guard found.count < maxPerRoot else { break }
                    guard !rootSet.contains(pid), seen.insert(pid).inserted else { continue }
                    found.append(pid)
                    next.append(contentsOf: (childrenByParent[pid] ?? []).sorted())
                }
                frontier = next
                depth += 1
            }
            if !found.isEmpty { out[root] = found }
        }
        return out
    }

    /// Whether a process has told us what it is: it holds a session file open,
    /// or it's named for an agent.
    static func identifiesAgent(_ info: ProcessInfo) -> Bool {
        info.openSessionFile != nil || isAgentCommand(info.command)
    }

    static func isAgentCommand(_ command: String) -> Bool {
        let c = command.lowercased()
        return c.hasPrefix("claude") || c.hasPrefix("codex")
    }

    /// The descendant that best explains what a wrapper is running: one holding
    /// a session file open beats one merely named for an agent. Deterministic
    /// (the caller's chain is pid-ordered) so a tab's identity doesn't flip
    /// between ticks when several children qualify.
    private static func agentDescendant(
        _ pids: some Sequence<Int32>, in probed: [Int32: ProcessInfo]
    ) -> ProcessInfo? {
        let candidates = pids.compactMap { probed[$0] }
        return candidates.first { $0.openSessionFile != nil }
            ?? candidates.first { isAgentCommand($0.command) }
    }

    /// pid → session id parsed from its argv (`--resume`/`-r`/`resume <id>`).
    /// `ps` because lsof doesn't expose argv. Empty if none match.
    static func resumeIDs(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let raw = run("/bin/ps", ["-ww", "-o", "pid=,command=", "-p", list]) else { return [:] }
        var out: [Int32: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let sp = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<sp]) else { continue }
            if let id = parseResumeID(String(trimmed[trimmed.index(after: sp)...])) { out[pid] = id }
        }
        return out
    }

    /// The session id following `--resume` / `-r` / `resume` in an argv string,
    /// if it looks like a session id (UUID-ish). Pure, for unit-testing.
    static func parseResumeID(_ argv: String) -> String? {
        let tokens = argv.split(separator: " ")
        guard tokens.count >= 2 else { return nil }
        for i in 0..<(tokens.count - 1) where tokens[i] == "--resume" || tokens[i] == "-r" || tokens[i] == "resume" {
            let cand = String(tokens[i + 1])
            if isSessionIDLike(cand) { return cand }
        }
        return nil
    }

    /// UUID-ish: hex digits and hyphens, long enough not to match a flag value.
    static func isSessionIDLike(_ s: String) -> Bool {
        s.count >= 16 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// Pure parse of lsof `-Fpcfn` output → per-pid process info. Split out so
    /// the field state-machine is unit-testable without spawning lsof.
    static func parse(_ raw: String, roots: [String]) -> [Int32: ProcessInfo] {
        var out: [Int32: (command: String, cwd: String?, file: String?)] = [:]
        var pid: Int32 = 0
        var command = ""
        var fd = ""
        for line in raw.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                command = ""
                if pid != 0 { out[pid] = (command: "", cwd: nil, file: nil) }
            case "c":
                command = value
                if pid != 0 { out[pid]?.command = command }
            case "f":
                fd = value
            case "n":
                guard pid != 0 else { break }
                if fd == "cwd" {
                    out[pid]?.cwd = value
                } else if out[pid]?.file == nil, value.hasSuffix(".jsonl"),
                          roots.contains(where: value.hasPrefix) {
                    out[pid]?.file = value
                }
            default:
                break
            }
        }
        return out.mapValues { ProcessInfo(command: $0.command, cwd: $0.cwd, openSessionFile: $0.file, resumeID: nil) }
    }

    private static func run(_ launchPath: String, _ args: [String]) -> String? {
        Subprocess.stdout(launchPath, args)
    }
}
