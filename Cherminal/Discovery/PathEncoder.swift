import Foundation

/// Claude Code stores per-cwd session directories under `~/.claude/projects/`
/// with the absolute path slug-encoded: `/Users/hamulia/dev/foo` becomes
/// `-Users-hamulia-dev-foo`. Dots inside path components are also turned into
/// dashes, so this decoder is best-effort — it walks the filesystem to confirm
/// the resolved candidate exists when possible.
enum PathEncoder {
    // Decoding is deterministic per encoded name and the filesystem layout is
    // stable for a session, but `decode` runs a `fileExists` probe per path
    // segment and is called for every project dir on every scan (and the
    // scanner runs off the main thread). Memoize so the segment-walk happens
    // once per encoded name instead of on every watcher-triggered rescan.
    private static let cacheLock = NSLock()
    private static var cache: [String: URL] = [:]

    /// Decode an encoded directory name back to an absolute URL on disk.
    /// Returns nil if no plausible path exists.
    static func decode(_ encoded: String) -> URL? {
        guard encoded.hasPrefix("-") else { return nil }

        cacheLock.lock()
        if let hit = cache[encoded] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let stripped = String(encoded.dropFirst())
        let segments = stripped.split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)

        // Resolve against the filesystem with longest-hyphen-match-first descent,
        // so a real hyphenated dir (e.g. `fantopy-hadi`) is preferred over a
        // split (`fantopy/hadi`) even when both exist on disk — the old greedy
        // one-segment walk silently picked the wrong nested path and cached it.
        if let resolved = resolve(segments: segments[...], base: URL(fileURLWithPath: "/")) {
            cacheLock.lock(); cache[encoded] = resolved; cacheLock.unlock()
            return resolved
        }
        // Fallback: join segments with `/`. Loses any original `-` in names, but
        // the sidebar still has *something* to render and group by. NOT cached —
        // the dir may simply not exist yet (or have a hyphen we mis-split), so a
        // later rescan should re-probe and self-heal rather than be stuck on the
        // lossy guess for the whole session.
        return URL(fileURLWithPath: "/" + segments.joined(separator: "/"))
    }

    /// Consume `segments` into existing directory components under `base`,
    /// trying the LONGEST hyphen-joined prefix first and backtracking. Returns a
    /// fully-resolved URL only when every segment is accounted for by real dirs.
    private static func resolve(segments: ArraySlice<String>, base: URL) -> URL? {
        if segments.isEmpty { return base }   // every segment accounted for
        let fm = FileManager.default
        for len in stride(from: segments.count, through: 1, by: -1) {
            let component = segments.prefix(len).joined(separator: "-")
            let candidate = base.appendingPathComponent(component)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let resolved = resolve(segments: segments.dropFirst(len), base: candidate) { return resolved }
        }
        return nil
    }
}
