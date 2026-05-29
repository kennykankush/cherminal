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
    }

    static func inspect(pids: [Int32]) -> [Int32: ProcessInfo] {
        guard !pids.isEmpty else { return [:] }
        let home = NSHomeDirectory()
        let roots = [home + "/.claude/projects/", home + "/.codex/sessions/"]
        let list = pids.map(String.init).joined(separator: ",")

        // +c 0: full command names. -Fpcfn: pid, command, fd, name fields — the
        // fd tells us which `n` is the cwd vs a regular open file.
        guard let raw = run("/usr/sbin/lsof", ["-p", list, "+c", "0", "-Fpcfn"]) else { return [:] }
        return parse(raw, roots: roots)
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
        return out.mapValues { ProcessInfo(command: $0.command, cwd: $0.cwd, openSessionFile: $0.file) }
    }

    private static func run(_ launchPath: String, _ args: [String]) -> String? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
