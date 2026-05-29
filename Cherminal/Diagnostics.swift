import Foundation
import os

/// Lightweight diagnostics. Mirrors structured action logs to a file in the
/// app's data dir AND to os_log, and captures a final breadcrumb + backtrace
/// on crash (uncaught exceptions and fatal signals). The breadcrumb matters
/// because libghostty C-layer faults often produce NO standard `.ips` crash
/// report — so without this, a "boom" leaves no trace.
///
/// View live:  `tail -f "<data-dir>/cherminal-debug.log"`
/// (path is printed to the system log via NSLog at launch)
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
        let url = dir.appendingPathComponent("cherminal-debug.log")
        logURL = url

        // Truncate on launch so each run starts clean (keeps the file small;
        // the last run's crash breadcrumb has already served its purpose).
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)

        installCrashHandlers()
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        log("app", "launch — Cherminal \(version) [\(subsystem)]")
        NSLog("[Cherminal] debug log → %@", url.path)
    }

    /// Log a structured action: `Diagnostics.log("tabs", "openOrFocus …")`.
    static func log(_ category: String, _ message: String) {
        osLogger.log("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = "\(timestamp()) [\(category)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) { try? fileHandle?.write(contentsOf: data) }
        }
    }

    // MARK: - Crash capture

    private static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.writeCrash(
                "uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "")",
                exception.callStackSymbols
            )
        }
        for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE] {
            signal(sig) { received in
                Diagnostics.writeCrash("signal \(received)", Thread.callStackSymbols)
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Synchronous best-effort write — we're about to die, so don't rely on
    /// the async queue. Opens its own handle to avoid touching shared state.
    private static func writeCrash(_ what: String, _ frames: [String]) {
        let text = "\n=== CRASH \(timestamp()) — \(what) ===\n"
            + frames.prefix(40).joined(separator: "\n") + "\n=== END CRASH ===\n"
        if let url = logURL, let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        }
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
