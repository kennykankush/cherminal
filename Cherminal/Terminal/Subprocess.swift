import Foundation
import os

/// The one way Cherminal spawns a short-lived probe process (lsof, ps, git,
/// grep, the login shell). Every call is watchdog-bounded: a child that wedges
/// (the classic is lsof stuck on a dead network mount) is SIGKILLed at the
/// timeout instead of hanging the caller forever — previously every probe in
/// the app did an unbounded `waitUntilExit()`, so one stuck lsof could freeze
/// a poll loop, or the quit path, indefinitely.
///
/// stdout is read to EOF *before* waiting (children like grep/zsh routinely
/// emit more than the 64 KB pipe buffer; waiting first deadlocks — the child
/// blocks writing, we block waiting). stderr goes to the null device so an
/// undrained pipe can't wedge the child mid-write.
enum Subprocess {
    struct Output {
        let stdout: String
        let status: Int32
    }

    /// Run `executable` with `args`, returning its stdout + exit status.
    /// nil when the process couldn't launch OR was killed by the watchdog —
    /// partial output from a timed-out child is suspect, so it's discarded.
    @discardableResult
    static func run(
        _ executable: String,
        _ args: [String],
        timeout: TimeInterval = 5
    ) -> Output? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }

        // Watchdog: SIGKILL (not SIGTERM — a D-state lsof ignores TERM) after
        // `timeout`. Killing closes the pipe, so the blocking read below always
        // returns. The flag records that the result is a timeout, not output.
        let pid = task.processIdentifier
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            kill(pid, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        guard !timedOut.withLock({ $0 }) else {
            clog("subprocess", "TIMEOUT (\(Int(timeout))s) — killed \(executable) \(args.prefix(3).joined(separator: " "))…")
            return nil
        }
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return Output(stdout: out, status: task.terminationStatus)
    }

    /// stdout-only convenience for callers that don't care about exit status
    /// (lsof/grep exit non-zero on "no matches", which isn't an error here).
    static func stdout(
        _ executable: String,
        _ args: [String],
        timeout: TimeInterval = 5
    ) -> String? {
        run(executable, args, timeout: timeout)?.stdout
    }

    /// POSIX single-quote: wrap in '…' and escape embedded quotes, so an
    /// interpolated path or command can never break the shell line it's
    /// embedded in. Shared by Dtach.wrap and TerminalCommand.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
