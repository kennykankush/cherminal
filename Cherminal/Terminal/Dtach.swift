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
        if let bundled = Bundle.main.url(forResource: "dtach", withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return BinaryResolver.shared.path(for: "dtach")
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
        return pgrepSocket(sock) != nil
    }

    /// End a detached session for good: SIGTERM the master (its child exits,
    /// and `dtach` follows), then remove the stale socket. Used by the tray's
    /// "Kill" action and the launch-time sweep.
    @discardableResult
    static func kill(id: String) -> Bool {
        let sock = socketPath(for: id)
        let killed: Bool
        if let pid = pgrepSocket(sock) {
            killed = Foundation.kill(pid, SIGTERM) == 0
        } else {
            killed = false
        }
        try? FileManager.default.removeItem(atPath: sock)
        return killed
    }

    /// All conversation ids that currently have a socket file on disk (alive or
    /// stale). The launch sweep reconciles these against live masters.
    static func knownSocketIDs() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { $0.hasSuffix(".sock") ? String($0.dropLast(5)) : nil }
    }

    // MARK: - Internals

    /// pid of the `dtach` master owning `socket`, via `pgrep -f` on the socket
    /// path (unique per conversation, so no false matches). nil if none.
    private static func pgrepSocket(_ socket: String) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", socket]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        // pgrep -f matches our own helper too is not a concern here: this
        // process is Cherminal, whose argv doesn't contain the socket path.
        return out.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .first
    }

    /// POSIX single-quote: wrap in '…' and escape embedded quotes. Used for the
    /// socket path and the inner command so neither can break the shell line.
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
