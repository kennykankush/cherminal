import Foundation
import Darwin
import os

// MARK: - Fault-capture state (file-scope globals)
//
// The signal handler must be async-signal-safe, so everything it touches is a
// plain global initialized once at bootstrap — no Swift lazy-init machinery,
// no allocation, no locks inside the handler.

/// Raw fd for the fault log. stderr is dup2'd onto this too, so libghostty
/// (Zig) panics, Swift `fatalError`/precondition messages, and any C `fprintf`
/// land here even when nothing else survives.
private var faultFD: Int32 = -1
private let backtraceSlots: Int32 = 128
private let backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(backtraceSlots))
private let crashHeader = Array("\n=== FATAL SIGNAL — backtrace follows ===\n".utf8)
private let crashFooter = Array("=== END BACKTRACE ===\n".utf8)

/// Lightweight diagnostics. Mirrors structured action logs to a file AND to
/// os_log (the os_log copy survives a crash and is queryable via `log show`),
/// and — critically — captures fatal faults in an async-signal-safe way plus
/// the process's stderr, because libghostty C/Zig faults otherwise leave NO
/// `.ips`, NO system-log entry, and NO breadcrumb.
///
/// Files in the app data dir:
///   • cherminal-debug.log  — structured breadcrumbs (this run; .prev = last)
///   • cherminal-fault.log  — stderr capture + crash backtraces (.prev = last)
enum Diagnostics {
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.hamulia.Cherminal"

    private static let osLogger = Logger(subsystem: subsystem, category: "diag")
    private static let queue = DispatchQueue(label: "\(subsystem).diag")
    private static var fileHandle: FileHandle?
    private(set) static var logURL: URL?

    /// Call once, as early as possible at launch.
    static func bootstrap() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return }
        let dir = support.appendingPathComponent(subsystem, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Breadcrumb log, rotated so a crash + relaunch keeps the prior run.
        let url = dir.appendingPathComponent("cherminal-debug.log")
        logURL = url
        rotate(url, in: dir, suffix: "debug")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)

        // Fault log: capture stderr (Zig/Swift/C panic text) + async-safe crash
        // backtraces. Separate, unbuffered fd that survives a malloc-time crash.
        let faultURL = dir.appendingPathComponent("cherminal-fault.log")
        rotate(faultURL, in: dir, suffix: "fault")
        faultFD = open(faultURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if faultFD >= 0 { dup2(faultFD, STDERR_FILENO) }
        // Force the handler's globals to initialize now, before any fault.
        _ = backtraceBuffer
        _ = crashHeader.count

        installCrashHandlers()
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        log("app", "launch — Cherminal \(version) [\(subsystem)]")
        NSLog("[Cherminal] logs → %@ (debug + fault)", dir.path)
    }

    /// Rotate `url` → `<base>.prev.log` so the previous run's evidence persists.
    private static func rotate(_ url: URL, in dir: URL, suffix: String) {
        let prev = dir.appendingPathComponent("cherminal-\(suffix).prev.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
    }

    /// Log a structured action: `Diagnostics.log("tabs", "openOrFocus …")`.
    static func log(_ category: String, _ message: String) {
        // os_log copy is synchronous + crash-durable (survives in the unified
        // log even if the async file write below is lost to a crash).
        osLogger.log("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = "\(timestamp()) [\(category)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) { try? fileHandle?.write(contentsOf: data) }
        }
    }

    // MARK: - Crash capture

    private static func installCrashHandlers() {
        // Uncaught Obj-C exceptions run in a normal context — rich logging is
        // safe here.
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.writeException(
                "uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "")",
                exception.callStackSymbols
            )
        }
        // Fatal signals: async-signal-safe ONLY. Pre-opened fd, no allocation,
        // no Foundation. `backtrace`/`backtrace_symbols_fd` are signal-safe and
        // write the stack straight to the fd.
        for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE] {
            signal(sig) { received in
                if faultFD >= 0 {
                    crashHeader.withUnsafeBufferPointer { _ = write(faultFD, $0.baseAddress, $0.count) }
                    let n = backtrace(backtraceBuffer, backtraceSlots)
                    backtrace_symbols_fd(backtraceBuffer, n, faultFD)
                    crashFooter.withUnsafeBufferPointer { _ = write(faultFD, $0.baseAddress, $0.count) }
                    fsync(faultFD)
                }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Rich write for the (safe) uncaught-exception path.
    private static func writeException(_ what: String, _ frames: [String]) {
        let text = "\n=== EXCEPTION \(timestamp()) — \(what) ===\n"
            + frames.prefix(40).joined(separator: "\n") + "\n=== END EXCEPTION ===\n"
        if faultFD >= 0 { _ = text.withCString { write(faultFD, $0, strlen($0)) } }
        NSLog("[Cherminal] %@", text)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

/// Convenience global so call sites stay terse: `clog("tabs", "…")`.
@inline(__always)
func clog(_ category: String, _ message: String) {
    Diagnostics.log(category, message)
}
