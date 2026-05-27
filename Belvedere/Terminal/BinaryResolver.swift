import Foundation
import os

/// Captures the user's shell-resolved environment so the commands Belvedere
/// spawns inside Ghostty surfaces find the same `claude` / `codex` / etc.
/// the user finds at their normal terminal.
///
/// Ghostty's `command:` path execs through `bash --noprofile --norc`, which
/// only inherits whatever PATH the host process already has. When Belvedere
/// is launched from the Dock, that's the minimal launchd PATH — `claude`
/// and `codex` aren't findable. Sourcing `~/.zshrc` ourselves once at app
/// startup and passing the resulting PATH (plus a few other env keys) into
/// every surface fixes that without touching the user's config.
///
/// We also expose `path(for:)` which returns the absolute path for a single
/// command if needed (e.g., when constructing a command string that's
/// evaluated outside Ghostty's exec path).
final class BinaryResolver: @unchecked Sendable {
    static let shared = BinaryResolver()

    private let logger = Logger(subsystem: "dev.hamulia.Belvedere", category: "binresolver")
    private let lock = NSLock()
    private var capturedPath: String?
    private var binaryCache: [String: String] = [:]

    /// Pull `PATH` (and a curated set of other useful env vars) out of the
    /// user's login + interactive zsh once. Call at app launch so subsequent
    /// `environment()` lookups are instant.
    func prewarm() {
        guard capturedPath == nil else { return }
        let sentinel = "BELVEDERE_ENV_BEGIN"
        let end = "BELVEDERE_ENV_END"
        let script = """
        printf '\\n%s\\n' '\(sentinel)'
        printf 'PATH=%s\\n' "$PATH"
        printf 'HOME=%s\\n' "$HOME"
        printf 'SHELL=%s\\n' "$SHELL"
        printf 'LANG=%s\\n' "$LANG"
        printf 'LC_ALL=%s\\n' "$LC_ALL"
        printf '%s\\n' '\(end)'
        """
        let raw = runLoginShell(script: script) ?? ""

        // Pull the chunk between sentinels — bypasses any fastfetch / motd
        // / git-prompt noise the user's rc files write to stdout.
        guard let beginRange = raw.range(of: sentinel),
              let endRange = raw.range(of: end, range: beginRange.upperBound..<raw.endIndex)
        else {
            logger.error("env sentinel not found in login shell output")
            return
        }
        let block = raw[beginRange.upperBound..<endRange.lowerBound]

        var captured: [String: String] = [:]
        for line in block.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)..<line.endIndex])
            if !value.isEmpty {
                captured[key] = value
            }
        }

        lock.lock()
        defer { lock.unlock() }
        capturedPath = captured["PATH"]
        capturedExtras = captured.filter { $0.key != "PATH" }
    }

    private var capturedExtras: [String: String] = [:]

    /// Env vars Belvedere injects into every Ghostty surface. The PATH
    /// entry is the load-bearing one; the rest are nice-to-haves so locale
    /// / shell-aware tools behave identically to the user's terminal.
    func environment() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var env: [String: String] = capturedExtras
        if let path = capturedPath {
            env["PATH"] = path
        }
        return env
    }

    /// Resolve a single command name to an absolute path using `command -v`
    /// inside the prewarmed PATH. Cached after first lookup.
    func path(for name: String) -> String {
        lock.lock()
        if let cached = binaryCache[name] {
            lock.unlock(); return cached
        }
        let path = capturedPath
        lock.unlock()

        guard let path else { return name }

        let resolved = lookup(name, inPath: path)
        lock.lock()
        binaryCache[name] = resolved ?? name
        lock.unlock()
        return resolved ?? name
    }

    // MARK: - Internals

    private func lookup(_ name: String, inPath path: String) -> String? {
        let fm = FileManager.default
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func runLoginShell(script: String) -> String? {
        let task = Process()
        task.launchPath = "/bin/zsh"
        // -i + -l reproduces the user's terminal: zprofile, zshrc, the
        // works. Yes, this can spawn fastfetch and friends — sentinels in
        // the script let us filter that noise back out.
        task.arguments = ["-ilc", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // discard
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
