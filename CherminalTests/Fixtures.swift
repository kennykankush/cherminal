import Foundation

/// Test helpers for writing throwaway session fixtures to disk and cleaning
/// them up. The parsers all take file URLs, so fixtures are real temp files.
enum Fixtures {
    /// Write `contents` to a unique temp `.jsonl` and return its URL. The file
    /// lives under the per-process temp dir; tests don't need to clean up
    /// (the OS reaps it), but `remove(_:)` is available for tidiness.
    static func writeJSONL(_ lines: [String], name: String = "fixture") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherminal-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).jsonl")
        let body = lines.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)!.write(to: url)
        return url
    }

    /// Append lines to an existing fixture (simulates an agent extending a
    /// live session file).
    static func append(_ lines: [String], to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let body = lines.joined(separator: "\n") + "\n"
        try? handle.write(contentsOf: body.data(using: .utf8)!)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
