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

    /// Inspect `pids` (one batched lsof). `argvByPID` / `startedByPID` — when
    /// the caller already holds a ProcTable snapshot — supply each pid's
    /// command line and start time so no second `ps` is spawned; without them
    /// we fall back to our own ps call (resume ids only).
    static func inspect(pids: [Int32],
                        argvByPID: [Int32: String]? = nil,
                        startedByPID: [Int32: Date]? = nil) -> [Int32: ProcessInfo] {
        guard !pids.isEmpty else { return [:] }
        let home = NSHomeDirectory()
        let roots = [home + "/.claude/projects/", home + "/.codex/sessions/"]
        let list = pids.map(String.init).joined(separator: ",")

        // +c 0: full command names. -Fpcfn: pid, command, fd, name fields — the
        // fd tells us which `n` is the cwd vs a regular open file.
        guard let raw = run("/usr/sbin/lsof", ["-p", list, "+c", "0", "-Fpcfn"]) else { return [:] }
        var info = parse(raw, roots: roots)
        // Merge in the exact resume id from each process's argv — lsof's command
        // field is only the name. This is the accurate session link for a
        // resumed agent (vs. guessing by room recency).
        let resumed: [Int32: String]
        if let argvByPID {
            var out: [Int32: String] = [:]
            for (pid, argv) in argvByPID where info[pid] != nil {
                if let id = parseResumeID(argv) { out[pid] = id }
            }
            resumed = out
        } else {
            resumed = resumeIDs(pids: pids)
        }
        for pid in info.keys {
            let cur = info[pid]!
            info[pid] = ProcessInfo(command: cur.command, cwd: cur.cwd,
                                    openSessionFile: cur.openSessionFile,
                                    resumeID: resumed[pid],
                                    launchArgv: argvByPID?[pid],
                                    startedAt: startedByPID?[pid])
        }
        return info
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
