import Foundation

/// One coherent snapshot of the process world, captured with exactly TWO
/// bounded subprocesses, answering every liveness question the app asks:
///
///   • which dtach masters are alive (who holds which socket open) — `lsof -U`
///   • parent/child links, controlling-terminal foreground groups, and full
///     argv per pid — one `ps -axww`
///
/// Before this, each question spawned its own probe: the 8s reconcile ran
/// lsof + pgrep + ps *per pane*, ports ran lsof + pgrep per pane, the tray ran
/// lsof per parked agent — ~3N+2 spawns a tick. A capture is 2 spawns
/// (~30 ms each), shared across consumers via `cached()`, and every consumer
/// sees the same instant instead of N temporally-skewed views.
struct ProcTable: Sendable {
    /// Socket path → pids holding it open. For a dtach socket lsof reports the
    /// listener (the master); a connected client holds only an unnamed peer.
    let socketHolders: [String: [pid_t]]
    let parent: [pid_t: pid_t]
    let childrenByParent: [pid_t: [pid_t]]
    /// Foreground process-group id of each pid's controlling terminal
    /// (`ps tpgid`); absent when the process has none (daemonized masters).
    let tpgid: [pid_t: pid_t]
    /// Full argv line per pid (`ps command=`) — also serves resume-id parsing,
    /// replacing the linker's separate ps call.
    let argv: [pid_t: String]

    func holders(ofSocket path: String) -> [pid_t] { socketHolders[path] ?? [] }
    func children(of pid: pid_t) -> [pid_t] { childrenByParent[pid] ?? [] }

    // MARK: - Capture

    /// Snapshot now. nil when either probe failed or timed out — callers must
    /// treat that as "unknown", never as "everything is dead" (a failed lsof
    /// marking every parked master dead would be a lie with consequences).
    static func capture(socketDir: URL) -> ProcTable? {
        guard let lsofRaw = Subprocess.stdout(
            "/usr/sbin/lsof", ["-U", "-a", "+c", "0", "-Fpcn"], timeout: 5),
            let psRaw = Subprocess.stdout(
                "/bin/ps", ["-axww", "-o", "pid=,ppid=,tpgid=,command="], timeout: 5)
        else { return nil }
        let sockets = parseLsofUnixSockets(lsofRaw, underDirectory: socketDir.path)
        let ps = parsePS(psRaw)
        return ProcTable(socketHolders: sockets,
                         parent: ps.parent,
                         childrenByParent: ps.children,
                         tpgid: ps.tpgid,
                         argv: ps.argv)
    }

    /// TTL-shared capture: the reconcile (8s), ports (12s), and tray refresh
    /// all want a table within moments of each other — one capture serves all.
    /// Thread-safe; intended for off-main callers (capture blocks ~60 ms).
    static func cached(socketDir: URL, maxAge: TimeInterval = 3) -> ProcTable? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let (stamp, table) = cacheEntry, Date().timeIntervalSince(stamp) < maxAge {
            return table
        }
        let fresh = capture(socketDir: socketDir)
        // Cache failures too (as nil) so a wedged lsof is retried at the TTL
        // cadence, not hammered by every consumer in the same tick.
        cacheEntry = (Date(), fresh)
        return fresh
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cacheEntry: (Date, ProcTable?)?

    // MARK: - Parsers (pure, unit-tested)

    /// Parse `lsof -U -Fpcn` records into socket-path → holder pids, keeping
    /// only paths under `underDirectory` (our dtach dir). A master holds the
    /// same path on several fds (listener + accepted client) — dedup per pid.
    static func parseLsofUnixSockets(_ raw: String, underDirectory dir: String) -> [String: [pid_t]] {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var out: [String: [pid_t]] = [:]
        var pid: pid_t = 0
        for line in raw.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                pid = pid_t(value) ?? 0
            case "n":
                guard pid > 0, value.hasPrefix(prefix) else { continue }
                let path = String(value)
                if out[path]?.contains(pid) != true {
                    out[path, default: []].append(pid)
                }
            default:
                break   // c (command) / f (fd) not needed here
            }
        }
        return out
    }

    /// Parse `ps -axww -o pid=,ppid=,tpgid=,command=`: three right-aligned
    /// numeric columns, then the raw command line (argv[0] may start with "-"
    /// for login processes — that dash is argv, not a sign).
    static func parsePS(_ raw: String) -> (
        parent: [pid_t: pid_t], children: [pid_t: [pid_t]],
        tpgid: [pid_t: pid_t], argv: [pid_t: String]
    ) {
        var parent: [pid_t: pid_t] = [:]
        var children: [pid_t: [pid_t]] = [:]
        var tpgid: [pid_t: pid_t] = [:]
        var argv: [pid_t: String] = [:]

        for line in raw.split(separator: "\n") {
            var rest = Substring(line)
            func nextInt() -> Int32? {
                rest = rest.drop(while: { $0 == " " })
                let neg = rest.first == "-"
                if neg { rest = rest.dropFirst() }
                let digits = rest.prefix(while: \.isNumber)
                guard !digits.isEmpty, let n = Int32(digits) else { return nil }
                rest = rest.dropFirst(digits.count)
                return neg ? -n : n
            }
            guard let pid = nextInt(), pid > 0,
                  let ppid = nextInt(),
                  let fg = nextInt() else { continue }
            // One separating space, then the command line verbatim.
            let command = String(rest.drop(while: { $0 == " " }))

            parent[pid] = ppid
            children[ppid, default: []].append(pid)
            if fg > 0 { tpgid[pid] = fg }
            if !command.isEmpty { argv[pid] = command }
        }
        return (parent, children, tpgid, argv)
    }
}
