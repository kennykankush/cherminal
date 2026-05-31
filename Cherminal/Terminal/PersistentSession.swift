import Foundation

/// Optional dtach-backed session persistence, behind the
/// `cherminal.persistentSessions` default (off → today's direct spawn).
///
/// Agents run inside a per-conversation `dtach` session, so they survive a tab
/// or app close and **reattach live** on reopen. dtach is a dumb PTY-keeper —
/// it does ZERO terminal emulation — so libghostty keeps doing all the
/// rendering and scrollback stays native (the whole reason we picked dtach over
/// tmux, which owns the screen and makes scrolling janky).
///
/// The magic is `dtach -A`: idempotent. Socket alive → reattach to the running
/// agent; socket gone → create the session and run the resume command. One
/// command covers first-open, reopen-while-working, reopen-after-exit, and
/// app-restart restore.
enum PersistentSession {
    /// User opt-in. When off, `available` is false and nothing changes.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "cherminal.persistentSessions") }

    /// Resolved dtach binary if installed; nil → silently fall back to direct
    /// spawn (so a missing dtach never breaks launching a tab).
    static let dtachPath: String? = {
        let p = BinaryResolver.shared.path(for: "dtach")
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }()

    static var available: Bool { enabled && dtachPath != nil }

    /// Per-conversation socket under a short ~/.cherminal path, so it stays well
    /// under the ~104-char `sun_path` limit (a long Application Support path
    /// would risk overflowing it).
    static func socketPath(for id: String) -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".cherminal/sessions")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("\(id).sock")
    }

    /// Liveness proxy for the sidebar live dot / attention light: the socket
    /// exists. Good enough — `dtach -A` reaps a stale socket on the next attach.
    /// (A precise check would confirm a listener; deferred.)
    static func isAlive(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: socketPath(for: id))
    }

    /// Wrap an inner shell command so it runs under this conversation's dtach
    /// session. Flags: `-A` reattach-or-create; `-r winch` redraw the agent's
    /// TUI at the current size on reattach; `-z` drop dtach's suspend handling;
    /// `-E` disable the detach hotkey (the GUI detaches by closing the window).
    /// `inner` is run via a non-login `/bin/zsh -c` (fast; no profile re-source)
    /// and must contain no single quotes — the resume line never does.
    static func wrap(_ inner: String, id: String) -> String? {
        guard let dtachPath else { return nil }
        let sock = socketPath(for: id)
        return "\(dtachPath) -A '\(sock)' -r winch -z -E /bin/zsh -c '\(inner)'"
    }
}
