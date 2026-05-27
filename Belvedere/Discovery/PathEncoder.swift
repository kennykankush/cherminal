import Foundation

/// Claude Code stores per-cwd session directories under `~/.claude/projects/`
/// with the absolute path slug-encoded: `/Users/hamulia/dev/foo` becomes
/// `-Users-hamulia-dev-foo`. Dots inside path components are also turned into
/// dashes, so this decoder is best-effort — it walks the filesystem to confirm
/// the resolved candidate exists when possible.
enum PathEncoder {
    /// Decode an encoded directory name back to an absolute URL on disk.
    /// Returns nil if no plausible path exists.
    static func decode(_ encoded: String) -> URL? {
        guard encoded.hasPrefix("-") else { return nil }
        let stripped = String(encoded.dropFirst())
        let segments = stripped.split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)

        // Fast path: every segment is a real directory name on disk.
        var url = URL(fileURLWithPath: "/")
        var ok = true
        for segment in segments {
            let candidate = url.appendingPathComponent(segment)
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            } else {
                ok = false
                break
            }
        }
        if ok { return url }

        // Fallback: join segments with `/`. Loses any original `-` in names, but
        // the sidebar still has *something* to render and group by.
        return URL(fileURLWithPath: "/" + segments.joined(separator: "/"))
    }
}
