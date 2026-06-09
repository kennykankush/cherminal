import Foundation
import os

/// Captures the user's shell-resolved environment so the commands Cherminal
/// spawns inside Ghostty surfaces find the same `claude` / `codex` / etc.
/// the user finds at their normal terminal.
///
/// Ghostty's `command:` path execs through `bash --noprofile --norc`, which
/// only inherits whatever PATH the host process already has. When Cherminal
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

    private let logger = Logger(subsystem: "dev.hamulia.Cherminal", category: "binresolver")
    private let lock = NSLock()
    private var capturedPath: String?
    private var capturedExtras: [String: String] = [:]
    private var binaryCache: [String: String] = [:]
    /// Last time a capture was started — gates the retry-on-failure cooldown.
    private var lastCaptureAttempt = Date.distantPast
    /// Balanced enter()/leave() around the background capture so the first
    /// surface spawn can wait for PATH without us blocking the launch thread.
    private let readyGroup = DispatchGroup()
    private var prewarmStarted = false

    /// Kick off shell-env capture on a background thread. Non-blocking: returns
    /// immediately so app launch is never gated on sourcing the user's
    /// `~/.zshrc` (which can run fastfetch, nvm, pyenv, … — easily seconds).
    /// `environment()` / `path(for:)` block briefly (bounded) the first time
    /// they're called if capture hasn't finished yet.
    func prewarm() {
        lock.lock()
        guard !prewarmStarted else { lock.unlock(); return }
        prewarmStarted = true
        readyGroup.enter()
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.readyGroup.leave() }
            self?.capture()
        }
    }

    /// Block until the background capture finishes, capped so a pathologically
    /// slow rc file can never hang a surface spawn. By the time the first
    /// surface spawns (after registry bootstrap's awaits) capture is normally
    /// already done, so this returns immediately in the common case.
    ///
    /// If the launch capture FAILED (shell timed out, sentinel missing), one
    /// later caller per cooldown re-attempts it synchronously — capture used to
    /// be strictly one-shot, so a single bad launch silently degraded every
    /// resume command to bare names for the whole session.
    private func waitUntilReady() {
        lock.lock(); let started = prewarmStarted; lock.unlock()
        guard started else { return }
        _ = readyGroup.wait(timeout: .now() + 3)

        lock.lock()
        let shouldRetry = capturedPath == nil
            && Date().timeIntervalSince(lastCaptureAttempt) > 30
        if shouldRetry { lastCaptureAttempt = Date() }   // claim the retry slot
        lock.unlock()
        if shouldRetry {
            logger.warning("env capture missing — retrying login-shell capture")
            capture()   // bounded by the subprocess timeout; off-main callers only
        }
    }

    /// Pull `PATH` (and a curated set of other useful env vars) out of the
    /// user's login + interactive zsh once.
    private func capture() {
        lock.lock(); lastCaptureAttempt = Date(); lock.unlock()
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

    /// Env vars Cherminal injects into every Ghostty surface. The PATH
    /// entry is the load-bearing one; the rest are nice-to-haves so locale
    /// / shell-aware tools behave identically to the user's terminal.
    func environment() -> [String: String] {
        waitUntilReady()
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
        waitUntilReady()
        lock.lock()
        if let cached = binaryCache[name] {
            lock.unlock(); return cached
        }
        let path = capturedPath
        lock.unlock()

        guard let path else { return name }

        let resolved = lookup(name, inPath: path)
        // Cache only successes. Caching the bare-name fallback meant a tool
        // installed mid-session (or a transient PATH glitch) stayed
        // unresolvable until relaunch.
        if let resolved {
            lock.lock()
            binaryCache[name] = resolved
            lock.unlock()
        }
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
        // -i + -l reproduces the user's terminal: zprofile, zshrc, the
        // works. Yes, this can spawn fastfetch and friends — sentinels in
        // the script let us filter that noise back out. 15s timeout: rc files
        // are legitimately slow (nvm, pyenv), but a hung shell (a prompt
        // waiting on input, a wedged plugin) must never poison the capture
        // forever — on timeout we return nil and a later call can retry.
        Subprocess.stdout("/bin/zsh", ["-ilc", script], timeout: 15)
    }
}
