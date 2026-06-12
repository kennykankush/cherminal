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
    /// Resident memory per pid in BYTES (`ps rss=` is KB; converted here) and
    /// instantaneous CPU percent (`ps pcpu=`) — the inspector's process facts.
    /// Same single sweep; two more columns, zero extra spawns.
    let rss: [pid_t: UInt64]
    let cpu: [pid_t: Double]
    /// When each process started (`ps etime=`, whole-second resolution) —
    /// lets the ledger refuse to link a fresh agent process to a conversation
    /// last written BEFORE the process existed (the new-chat misattribution).
    let startedAt: [pid_t: Date]

    init(socketHolders: [String: [pid_t]],
         parent: [pid_t: pid_t],
         childrenByParent: [pid_t: [pid_t]],
         tpgid: [pid_t: pid_t],
         argv: [pid_t: String],
         rss: [pid_t: UInt64] = [:],
         cpu: [pid_t: Double] = [:],
         startedAt: [pid_t: Date] = [:]) {
        self.socketHolders = socketHolders
        self.parent = parent
        self.childrenByParent = childrenByParent
        self.tpgid = tpgid
        self.argv = argv
        self.rss = rss
        self.cpu = cpu
        self.startedAt = startedAt
    }

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
                "/bin/ps", ["-axww", "-o", "pid=,ppid=,tpgid=,rss=,pcpu=,etime=,command="], timeout: 5)
        else { return nil }
        let sockets = parseLsofUnixSockets(lsofRaw, underDirectory: socketDir.path)
        let ps = parsePS(psRaw)
        return ProcTable(socketHolders: sockets,
                         parent: ps.parent,
                         childrenByParent: ps.children,
                         tpgid: ps.tpgid,
                         argv: ps.argv,
                         rss: ps.rss,
                         cpu: ps.cpu,
                         startedAt: ps.startedAt)
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

    /// Parse `ps -axww -o pid=,ppid=,tpgid=,rss=,pcpu=,etime=,command=`: four
    /// right-aligned integer columns, a decimal CPU column, an elapsed-time
    /// column, then the raw command line (argv[0] may start with "-" for
    /// login processes — that dash is argv, not a sign). rss arrives in KB
    /// and is stored as bytes; etime becomes an absolute start Date.
    static func parsePS(_ raw: String, now: Date = Date()) -> (
        parent: [pid_t: pid_t], children: [pid_t: [pid_t]],
        tpgid: [pid_t: pid_t], argv: [pid_t: String],
        rss: [pid_t: UInt64], cpu: [pid_t: Double],
        startedAt: [pid_t: Date]
    ) {
        var parent: [pid_t: pid_t] = [:]
        var children: [pid_t: [pid_t]] = [:]
        var tpgid: [pid_t: pid_t] = [:]
        var argv: [pid_t: String] = [:]
        var rss: [pid_t: UInt64] = [:]
        var cpu: [pid_t: Double] = [:]
        var startedAt: [pid_t: Date] = [:]

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
            func nextDecimal() -> Double? {
                rest = rest.drop(while: { $0 == " " })
                let token = rest.prefix(while: { $0.isNumber || $0 == "." })
                guard !token.isEmpty, let v = Double(token) else { return nil }
                rest = rest.dropFirst(token.count)
                return v
            }
            func nextToken() -> Substring {
                rest = rest.drop(while: { $0 == " " })
                let token = rest.prefix(while: { $0 != " " })
                rest = rest.dropFirst(token.count)
                return token
            }
            guard let pid = nextInt(), pid > 0,
                  let ppid = nextInt(),
                  let fg = nextInt(),
                  let rssKB = nextInt(),
                  let pcpu = nextDecimal() else { continue }
            let elapsed = parseElapsed(nextToken())
            // One separating space, then the command line verbatim.
            let command = String(rest.drop(while: { $0 == " " }))

            parent[pid] = ppid
            children[ppid, default: []].append(pid)
            if fg > 0 { tpgid[pid] = fg }
            if !command.isEmpty { argv[pid] = command }
            if rssKB > 0 { rss[pid] = UInt64(rssKB) * 1024 }
            cpu[pid] = pcpu
            if let elapsed { startedAt[pid] = now.addingTimeInterval(-elapsed) }
        }
        return (parent, children, tpgid, argv, rss, cpu, startedAt)
    }

    /// `ps etime=` → seconds: `mm:ss`, `hh:mm:ss`, or `dd-hh:mm:ss`.
    static func parseElapsed(_ token: Substring) -> TimeInterval? {
        guard !token.isEmpty else { return nil }
        var days = 0
        var clock = token
        if let dash = token.firstIndex(of: "-") {
            guard let d = Int(token[..<dash]) else { return nil }
            days = d
            clock = token[token.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        let (h, m, s) = values.count == 3 ? (values[0], values[1], values[2])
                                          : (0, values[0], values[1])
        return TimeInterval(((days * 24 + h) * 60 + m) * 60 + s)
    }
}
