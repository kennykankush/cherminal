import Foundation

/// A development server listening on a local TCP port, attributed (where
/// possible) to the room and conversation that spawned it.
struct DevPort: Identifiable, Equatable, Sendable {
    let port: Int
    let command: String          // process name, e.g. "node"
    let pid: Int32
    let category: Category
    let cwd: String?
    let roomName: String?        // attributed room (cwd under a known room)
    let conversationID: String?  // exact chat, if the server descends from a tab

    var id: Int { port }

    enum Category: String, CaseIterable, Sendable {
        case frontend = "Frontend"
        case backend  = "Backend"
        case database = "Database"
        case other    = "Other"

        /// Bucket a port number. Worktree spillovers (e.g. 3000→3042, 4200→4251)
        /// land in the same category as their base. Ordered: first match wins.
        static func of(_ port: Int) -> Category {
            // Database first (specific, unambiguous).
            if [5432, 5433, 3306, 27017, 6379, 9042].contains(port) { return .database }
            // Specific backend ports that sit *inside* a frontend band — checked
            // before the ranges below or they'd be miscategorized as frontend
            // (3001 = API next to a 3000 frontend; 8787 = wrangler).
            if port == 3001 || port == 8787 { return .backend }
            // Frontend dev-server bands.
            if (3000...3099).contains(port)      // Next / CRA / Remix (+worktree offsets)
                || (4200...4299).contains(port)  // Angular (+offsets)
                || (5173...5199).contains(port)  // Vite (+offsets)
                || port == 8080 || port == 1420  // common frontend / Tauri
            { return .frontend }
            // Backend / API bands.
            if (4000...4099).contains(port)      // common Node/Go API (+offsets)
                || (8000...8099).contains(port)  // Django / FastAPI / misc (+offsets)
                || (9000...9099).contains(port)
            { return .backend }
            return .other
        }
    }
}

/// Scans local listening ports via `lsof`, keeps only dev servers whose
/// working directory lives under a known room (auto-excluding Spotify /
/// AirPlay / system noise), categorizes them, and attributes each to a room
/// and — when the server descends from a tab's process — a conversation.
///
/// Pure external observation (no injection): `lsof` + `ps` only.
enum PortScanner {
    /// Inputs the manager supplies each scan.
    struct Context: Sendable {
        /// Absolute room paths (e.g. every `~/dev/<room>`), longest-match wins.
        let roomPaths: [String]
        /// foreground process pid → conversation id, for exact attribution.
        let tabPIDs: [Int32: String]
        /// Roots a server cwd must fall under to count as "ours".
        let devRoots: [String]
    }

    static func scan(_ context: Context) -> [DevPort] {
        let listeners = listeningPorts()
        guard !listeners.isEmpty else { return [] }

        let pids = Set(listeners.map { $0.pid })
        let cwds = cwdsFor(pids: pids)
        let parents = parentMap()

        var out: [DevPort] = []
        var seenPorts = Set<Int>()

        for l in listeners.sorted(by: { $0.port < $1.port }) {
            guard !seenPorts.contains(l.port) else { continue }  // collapse v4/v6
            guard let cwd = cwds[l.pid] else { continue }

            // Scope: only servers whose cwd is under a dev root.
            guard context.devRoots.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { continue }
            seenPorts.insert(l.port)

            // Room = longest known room path that prefixes the cwd.
            let room = context.roomPaths
                .filter { cwd == $0 || cwd.hasPrefix($0 + "/") }
                .max(by: { $0.count < $1.count })

            // Conversation = walk the listener's ancestry to a tab's fg pid.
            let convo = attributeConversation(pid: l.pid, parents: parents, tabPIDs: context.tabPIDs)

            out.append(DevPort(
                port: l.port,
                command: l.command,
                pid: l.pid,
                category: refinedCategory(port: l.port, command: l.command),
                cwd: cwd,
                roomName: room.map { URL(fileURLWithPath: $0).lastPathComponent },
                conversationID: convo
            ))
        }
        return out
    }

    /// Process name is ground truth for databases — the port can be remapped,
    /// but `postgres`/`redis`/`mongod` are unambiguous. For frontend vs backend
    /// the process is usually just `node`/`python`, so those stay port-based.
    static func refinedCategory(port: Int, command: String) -> DevPort.Category {
        let c = command.lowercased()
        if c.hasPrefix("postgres") || c.hasPrefix("postmaster") || c.hasPrefix("mysqld")
            || c.hasPrefix("mariadb") || c.hasPrefix("mongod") || c.hasPrefix("redis") {
            return .database
        }
        return .of(port)
    }

    // MARK: - lsof: listening ports

    private struct Listener { let pid: Int32; let command: String; let port: Int }

    private static func listeningPorts() -> [Listener] {
        // -nP: no DNS/port-name lookups (fast). +c 0: don't truncate the command
        // name (so we get `redis-server`, not `redis-ser`). -Fpcn: fields.
        guard let raw = run("/usr/sbin/lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return [] }
        var out: [Listener] = []
        var pid: Int32 = 0
        var command = ""
        for line in raw.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                // e.g. "127.0.0.1:3000" or "[::1]:5174" or "*:24678"
                if let portStr = value.split(separator: ":").last,
                   let port = Int(portStr) {
                    out.append(Listener(pid: pid, command: command, port: port))
                }
            default: break
            }
        }
        return out
    }

    // MARK: - lsof: cwd per pid

    private static func cwdsFor(pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let raw = run("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fpn"]) else { return [:] }
        var out: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in raw.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "n": if pid != 0 { out[pid] = value }
            default: break
            }
        }
        return out
    }

    // MARK: - ps: pid → ppid map for ancestry

    private static func parentMap() -> [Int32: Int32] {
        guard let raw = run("/bin/ps", ["-axo", "pid=,ppid="]) else { return [:] }
        var out: [Int32: Int32] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) {
                out[pid] = ppid
            }
        }
        return out
    }

    /// Walk up from `pid`; if any ancestor is a tab's foreground pid, that's
    /// the conversation that spawned this server.
    private static func attributeConversation(
        pid: Int32,
        parents: [Int32: Int32],
        tabPIDs: [Int32: String]
    ) -> String? {
        var current = pid
        var guardCount = 0
        while current > 1 && guardCount < 64 {
            if let convo = tabPIDs[current] { return convo }
            guard let parent = parents[current] else { break }
            current = parent
            guardCount += 1
        }
        return nil
    }

    // MARK: - Subprocess helper

    private static func run(_ launchPath: String, _ args: [String]) -> String? {
        Subprocess.stdout(launchPath, args)
    }
}
