import Foundation

/// Persistent-session glue around `dtach`. We run agent commands under a
/// `dtach` master so the agent process survives the surface being torn down
/// (app quit/crash, or — once the tray lands — closing a pane to "detach"
/// it). The master lives in its own session (setsid); freeing the Ghostty
/// surface SIGHUPs only the in-PTY *client*, never the master.
///
/// `dtach -A <socket>` is the linchpin: it attaches to the socket, creating
/// the master if absent. So the *same* spawn command both starts a fresh
/// agent (socket missing → create + run) and reattaches a survivor (socket
/// live → attach; the inner command is ignored). Restore needs no special
/// reattach path — it just respawns with the same socket.
///
/// Only resumed agent panes are wrapped; bare shells aren't (nothing worth
/// keeping alive, and their foreground-pid liveness detection must stay raw).
enum Dtach {
    /// `~/.cherminal/dtach/<bundle-id>`, created on demand. One socket per
    /// conversation id, namespaced by bundle so separate app instances never
    /// share a socket dir. This is critical: the launch sweep kills masters not
    /// in *this* instance's saved set, so a shared dir made CherminalDev's sweep
    /// reap the daily driver's live agents (and vice versa) → "Process exited"
    /// under a running agent. Per-bundle dirs keep each instance's masters its
    /// own; the sweep can only ever touch sockets it created.
    static var directory: URL {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.hamulia.Cherminal"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cherminal/dtach", isDirectory: true)
            .appendingPathComponent(bundle, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Socket path for a conversation. Stable across launches (keyed on the
    /// agent's session id), so a relaunch reattaches the same master. Unix
    /// socket paths cap ~104 chars; `<home>/.cherminal/dtach/<uuid>.sock` fits.
    static func socketPath(for id: String) -> String {
        directory.appendingPathComponent("\(id).sock").path
    }

    /// The `dtach` executable: the binary bundled in the app (daily driver)
    /// wins; otherwise the user's PATH (dev against Homebrew's dtach).
    static func binaryPath() -> String {
        // Bundled at Contents/MacOS/dtach (the helper-executable location) — see
        // project.yml's "Bundle dtach" step.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "dtach")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return BinaryResolver.shared.path(for: "dtach")
    }

    /// Opt-in (`cherminal.persistentSessions`, default off): wrap EVERY pane —
    /// plain shells/tmux/vim, not just resumed agents — under a dtach master, so
    /// any process survives close/quit and reattaches live on reopen. Off keeps
    /// today's behavior (only agents wrapped).
    static var wrapAllPanes: Bool {
        UserDefaults.standard.bool(forKey: "cherminal.persistentSessions")
    }

    /// Wrap an inner shell command so it runs under a persistent master keyed
    /// to `id`. The inner line runs via `/bin/sh -c` *inside* the master so its
    /// `; exec $SHELL` fallback and any `${VAR}` expand there — keeping the
    /// whole agent→shell chain alive under one master. `-z` disables dtach's
    /// own detach keystroke (invisible; all keys reach the agent); `-r winch`
    /// makes the TUI repaint on reattach so you land on a live screen.
    static func wrap(_ inner: String, id: String) -> String {
        let sock = quote(socketPath(for: id))
        let bin = binaryPath()
        return "\(bin) -A \(sock) -z -r winch /bin/sh -c \(quote(inner))"
    }

    /// Is a master still alive for this conversation? True iff a `dtach`
    /// process holds the socket open. Cheap enough for the tray's poll.
    static func isMasterAlive(id: String) -> Bool {
        let sock = socketPath(for: id)
        guard FileManager.default.fileExists(atPath: sock) else { return false }
        return !socketHolderPIDs(sock).isEmpty
    }

    /// End a detached session for good: SIGTERM the master (its child exits,
    /// and `dtach` follows), then remove the stale socket. Used by the tray's
    /// "Kill" action and the launch-time sweep.
    @discardableResult
    static func kill(id: String) -> Bool {
        let sock = socketPath(for: id)
        // SIGTERM the process holding this socket open — the master. lsof reports
        // the listener (the master), not connected clients; killing the master
        // makes it SIGHUP its child (the agent), and any attached client follows
        // when the master goes. Then we unlink the (now stale) socket below.
        let pids = socketHolderPIDs(sock)
        for pid in pids { _ = Foundation.kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(atPath: sock)
        return !pids.isEmpty
    }

    /// All conversation ids that currently have a socket file on disk (alive or
    /// stale). The launch sweep reconciles these against live masters.
    static func knownSocketIDs() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { $0.hasSuffix(".sock") ? String($0.dropLast(5)) : nil }
    }

    // MARK: - Seeing through dtach (the master/child tree)

    /// The `dtach` master holding a wrapped pane's socket. The surface's
    /// foreground process is the dtach CLIENT (a childless relay); the master —
    /// which actually runs the inner shell/agent on its own pty — is the
    /// socket-matching process that HAS a child. Returns nil WITHOUT shelling out
    /// when the pane isn't wrapped (socket file absent), so the off-by-default
    /// path adds no per-pane subprocess.
    static func masterPID(id: String) -> pid_t? {
        let sock = socketPath(for: id)
        guard FileManager.default.fileExists(atPath: sock) else { return nil }
        let matches = socketHolderPIDs(sock)
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] }
        // Master = the socket holder with a child (the inner shell). The client
        // is a leaf relay. (ppid is unreliable: with a client attached the master's
        // parent is the client, not launchd.)
        return matches.first(where: { !childPIDs(of: $0).isEmpty }) ?? matches[0]
    }

    /// The real inner foreground process under a wrapped pane's master: the inner
    /// shell's current job (a hand-launched agent) if any, else the inner shell.
    /// nil when the pane isn't wrapped. Lets live detection / adoption see THROUGH
    /// dtach, since the surface's own foreground pid is just the client relay.
    static func innerForegroundPID(id: String) -> pid_t? {
        let sock = socketPath(for: id)
        guard FileManager.default.fileExists(atPath: sock) else { return nil }
        let matches = socketHolderPIDs(sock)
        guard !matches.isEmpty else { return nil }
        // Find the master AND its inner-shell child in one pass over the socket
        // matches (master = the one WITH a child; the client is a childless relay),
        // so we don't re-run the pgrep -P that the separate masterPID already does.
        var master = matches[0]
        var shell: pid_t?
        if matches.count == 1 {
            shell = childPIDs(of: master).first
        } else {
            for m in matches where shell == nil {
                if let kid = childPIDs(of: m).first { master = m; shell = kid }
            }
        }
        guard let shell else { return master }
        // The inner pty's foreground process group (tpgid) — its leader pid is the
        // ACTIVE foreground process (a hand-launched agent), or the shell's own pid
        // when it's at a prompt. Foreground-aware, unlike "first child" which could
        // be a background job (e.g. `npm run dev &`).
        if let fg = terminalForegroundPID(of: shell), fg > 0 { return fg }
        return shell
    }

    /// The foreground process group id of `pid`'s controlling terminal (ps tpgid).
    /// That id is the foreground group leader's pid — the active foreground process
    /// on the pty. nil if it has no controlling tty / no foreground group.
    private static func terminalForegroundPID(of pid: pid_t) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tpgid=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let tpgid = pid_t(raw), tpgid > 0 else { return nil }
        return tpgid
    }

    /// Direct child pids of `pid` (pgrep -P).
    static func childPIDs(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Internals

    /// pid(s) of the `dtach` process(es) holding `socket` OPEN — the master.
    ///
    /// We use `lsof` on the socket FILE, NOT `pgrep -f <socketpath>`. A daemonized
    /// dtach master (the one that actually runs the agent, reparented to launchd)
    /// is INVISIBLE to pgrep on macOS — `pgrep -f` returns nothing for it on any
    /// substring, and even `pgrep -x dtach` misses it — while `ps` and `lsof` both
    /// see it fine. That blindness silently broke all see-through-dtach detection
    /// (agents never marked live → "your turn" / minimap never lit). lsof reports
    /// the listener (the master); connected clients don't hold the *named* socket
    /// path open, so this returns the master cleanly. [] if none (stale socket).
    private static func socketHolderPIDs(_ socket: String) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", socket]   // -t: terse, pids only
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// POSIX single-quote: wrap in '…' and escape embedded quotes. Used for the
    /// socket path and the inner command so neither can break the shell line.
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
