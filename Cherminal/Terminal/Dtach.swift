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
    /// Everything interpolated — the binary, the socket, the inner command —
    /// is quoted, so no path can break the shell line.
    static func wrap(_ inner: String, id: String) -> String {
        let sock = Subprocess.quote(socketPath(for: id))
        let bin = Subprocess.quote(binaryPath())
        return "\(bin) -A \(sock) -z -r winch /bin/sh -c \(Subprocess.quote(inner))"
    }

    /// Is a master still alive for this conversation? True iff a `dtach`
    /// process holds the socket open. Cheap enough for the tray's poll.
    static func isMasterAlive(id: String) -> Bool {
        let sock = socketPath(for: id)
        guard FileManager.default.fileExists(atPath: sock) else { return false }
        return !socketHolderPIDs(sock).isEmpty
    }

    /// Master liveness answered from a process snapshot — no subprocess.
    static func isMasterAlive(id: String, table: ProcTable) -> Bool {
        !table.holders(ofSocket: socketPath(for: id)).isEmpty
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
    //
    // The resolution LAW lives once, in `resolveMaster` / `resolveInner`, and
    // is consumed two ways: the snapshot path (a ProcTable, zero subprocesses
    // per question — what the poll loops use) and the legacy single-socket
    // path (per-socket lsof/pgrep/ps, kept for one-off questions like "can
    // this one pane park?" where a full snapshot would be overkill).

    /// The `dtach` master holding a wrapped pane's socket, answered from a
    /// process snapshot — no subprocess.
    static func masterPID(id: String, table: ProcTable) -> pid_t? {
        resolveMaster(holders: table.holders(ofSocket: socketPath(for: id)),
                      children: table.children(of:))
    }

    /// The `dtach` master holding a wrapped pane's socket (single-shot probe).
    /// Returns nil WITHOUT shelling out when the pane isn't wrapped (socket
    /// file absent), so the off-by-default path adds no per-pane subprocess.
    static func masterPID(id: String) -> pid_t? {
        let sock = socketPath(for: id)
        guard FileManager.default.fileExists(atPath: sock) else { return nil }
        return resolveMaster(holders: socketHolderPIDs(sock), children: childPIDs(of:))
    }

    /// The real inner foreground process under a wrapped pane's master,
    /// answered from a process snapshot — no subprocess.
    static func innerForegroundPID(id: String, table: ProcTable) -> pid_t? {
        resolveInner(holders: table.holders(ofSocket: socketPath(for: id)),
                     children: table.children(of:),
                     foregroundGroup: { table.tpgid[$0] })
    }

    /// The real inner foreground process under a wrapped pane's master: the inner
    /// shell's current job (a hand-launched agent) if any, else the inner shell.
    /// nil when the pane isn't wrapped. Lets live detection / adoption see THROUGH
    /// dtach, since the surface's own foreground pid is just the client relay.
    static func innerForegroundPID(id: String) -> pid_t? {
        let sock = socketPath(for: id)
        guard FileManager.default.fileExists(atPath: sock) else { return nil }
        return resolveInner(holders: socketHolderPIDs(sock),
                            children: childPIDs(of:),
                            foregroundGroup: terminalForegroundPID(of:))
    }

    /// The master among a socket's holders. The surface's foreground process is
    /// the dtach CLIENT (a childless relay); the master — which actually runs
    /// the inner shell/agent on its own pty — is the socket-matching process
    /// that HAS a child. (ppid is unreliable: with a client attached the
    /// master's parent is the client, not launchd.)
    private static func resolveMaster(holders: [pid_t], children: (pid_t) -> [pid_t]) -> pid_t? {
        guard !holders.isEmpty else { return nil }
        if holders.count == 1 { return holders[0] }
        return holders.first(where: { !children($0).isEmpty }) ?? holders[0]
    }

    /// Master → inner shell → the pty's foreground group leader. The tpgid is
    /// the ACTIVE foreground process (a hand-launched agent), or the shell's
    /// own pid when it's at a prompt — foreground-aware, unlike "first child"
    /// which could be a background job (e.g. `npm run dev &`).
    private static func resolveInner(
        holders: [pid_t],
        children: (pid_t) -> [pid_t],
        foregroundGroup: (pid_t) -> pid_t?
    ) -> pid_t? {
        guard !holders.isEmpty else { return nil }
        var master = holders[0]
        var shell: pid_t?
        if holders.count == 1 {
            shell = children(master).first
        } else {
            for m in holders where shell == nil {
                if let kid = children(m).first { master = m; shell = kid }
            }
        }
        guard let shell else { return master }
        if let fg = foregroundGroup(shell), fg > 0 { return fg }
        return shell
    }

    /// The foreground process group id of `pid`'s controlling terminal (ps tpgid).
    /// That id is the foreground group leader's pid — the active foreground process
    /// on the pty. nil if it has no controlling tty / no foreground group.
    private static func terminalForegroundPID(of pid: pid_t) -> pid_t? {
        guard let raw = Subprocess.stdout("/bin/ps", ["-o", "tpgid=", "-p", String(pid)]) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tpgid = pid_t(trimmed), tpgid > 0 else { return nil }
        return tpgid
    }

    /// Direct child pids of `pid` (pgrep -P).
    static func childPIDs(of pid: pid_t) -> [pid_t] {
        guard let out = Subprocess.stdout("/usr/bin/pgrep", ["-P", String(pid)]) else { return [] }
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
        guard let out = Subprocess.stdout("/usr/sbin/lsof", ["-t", socket]) else { return [] }
        return out.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}
