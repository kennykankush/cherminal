import Foundation

/// A room's working-tree state, read-only. Pure external observation — runs
/// `git` in the room dir, never writes (uses `--no-optional-locks` so a poll
/// can't even touch the index lock and interfere with the agent's own git).
struct GitStatus: Equatable, Sendable {
    var branch: String          // branch name, or short SHA when detached
    var detached: Bool
    var ahead: Int
    var behind: Int
    var hasUpstream: Bool
    var changedPaths: [String]  // working-tree changes (tracked + untracked), capped
    var changedCount: Int       // total changed files (may exceed changedPaths.count)
    var insertions: Int         // ± vs HEAD (tracked changes; untracked add no lines)
    var deletions: Int
    var isClean: Bool { changedCount == 0 }
}

/// Reads `GitStatus` for a room. Two cheap `git` calls; returns nil when the
/// path isn't a git repo (so the inspector simply hides the section).
enum GitStatusReader {
    private static let pathCap = 12

    static func read(roomPath: URL) -> GitStatus? {
        // One call gives branch + ahead/behind + the changed-file list.
        guard let status = git([
            "-C", roomPath.path, "-c", "core.quotepath=false", "--no-optional-locks",
            "status", "--porcelain", "--branch",
        ]) else { return nil }   // non-zero exit = not a repo / git unavailable

        var branch = ""
        var detached = false
        var ahead = 0, behind = 0
        var hasUpstream = false
        var paths: [String] = []
        var count = 0

        for raw in status.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                let info = String(line.dropFirst(3))
                if info.hasPrefix("HEAD (no branch)") {
                    detached = true
                } else if info.hasPrefix("No commits yet on ") {
                    branch = String(info.dropFirst("No commits yet on ".count))
                } else {
                    // "branch...upstream [ahead N, behind M]" (upstream/bracket optional)
                    let head = info.split(separator: " ").first.map(String.init) ?? info
                    if let r = head.range(of: "...") {
                        branch = String(head[head.startIndex..<r.lowerBound]); hasUpstream = true
                    } else {
                        branch = head
                    }
                    ahead = number(after: "ahead ", in: info) ?? 0
                    behind = number(after: "behind ", in: info) ?? 0
                }
            } else if !line.isEmpty {
                count += 1
                if paths.count < pathCap { paths.append(changedPath(from: line)) }
            }
        }

        if detached,
           let sha = git(["-C", roomPath.path, "rev-parse", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
            branch = sha
        }

        var ins = 0, del = 0
        if let stat = git(["-C", roomPath.path, "--no-optional-locks", "diff", "--shortstat", "HEAD"]) {
            (ins, del) = parseShortstat(stat)
        }

        return GitStatus(branch: branch, detached: detached, ahead: ahead, behind: behind,
                         hasUpstream: hasUpstream, changedPaths: paths, changedCount: count,
                         insertions: ins, deletions: del)
    }

    // MARK: - Parse helpers (split out so they're unit-testable)

    /// The path from a `git status --porcelain` line: drop the 2-char XY code +
    /// space; for a rename ("old -> new") keep the new path.
    static func changedPath(from line: String) -> String {
        let p = line.count > 3 ? String(line.dropFirst(3)) : line
        if let r = p.range(of: " -> ") { return String(p[r.upperBound...]) }
        return p
    }

    /// First integer following `token` in `s` (e.g. "ahead " → 2 in "[ahead 2]").
    static func number(after token: String, in s: String) -> Int? {
        guard let r = s.range(of: token) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// "(N files changed,) X insertions(+), Y deletions(-)" → (X, Y).
    static func parseShortstat(_ s: String) -> (Int, Int) {
        var ins = 0, del = 0
        for part in s.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            let n = Int(t.split(separator: " ").first ?? "") ?? 0
            if t.contains("insertion") { ins = n }
            if t.contains("deletion") { del = n }
        }
        return (ins, del)
    }

    private static func git(_ args: [String]) -> String? {
        // 10s: `status` on a huge cold-cache repo can take a few seconds;
        // a repo on a dead mount must still never wedge the poll.
        guard let out = Subprocess.run("/usr/bin/git", args, timeout: 10),
              out.status == 0 else { return nil }
        return out.stdout
    }
}
