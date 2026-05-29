import Testing
import Foundation
@testable import Cherminal

struct PathEncoderTests {

    @Test func returnsNilWithoutLeadingDash() {
        #expect(PathEncoder.decode("Users-hamulia-dev") == nil)
    }

    @Test func fallsBackToSlashJoinForNonexistentPath() {
        // No such path on disk → the fallback joins segments with "/". (It
        // can't recover hyphens inside a component, which is the documented
        // limitation the scanner works around via the recorded cwd.)
        let url = PathEncoder.decode("-nope-zzz-\(UUID().uuidString)-leaf")
        #expect(url?.path.hasPrefix("/nope/zzz/") == true)
    }

    @Test func resolvesRealPathOnDisk() {
        // The home dir definitely exists; encode it and confirm the fast path
        // walks it back exactly.
        let home = NSHomeDirectory()                       // e.g. /Users/alice
        let encoded = "-" + home.dropFirst().replacingOccurrences(of: "/", with: "-")
        #expect(PathEncoder.decode(encoded)?.path == home)
    }
}

struct PortCategoryTests {

    @Test func bucketsKnownPorts() {
        #expect(DevPort.Category.of(3000) == .frontend)
        #expect(DevPort.Category.of(3042) == .frontend)   // worktree offset
        #expect(DevPort.Category.of(5173) == .frontend)   // vite
        #expect(DevPort.Category.of(1420) == .frontend)   // tauri
        #expect(DevPort.Category.of(5432) == .database)   // postgres
        #expect(DevPort.Category.of(6379) == .database)   // redis
        #expect(DevPort.Category.of(8000) == .backend)    // django/fastapi
        #expect(DevPort.Category.of(3001) == .backend)    // api-next-to-3000
        #expect(DevPort.Category.of(54321) == .other)
    }

    @Test func processNameOverridesPortForDatabases() {
        // Postgres on a non-standard (frontend-band) port is still a database.
        #expect(PortScanner.refinedCategory(port: 3000, command: "postgres") == .database)
        #expect(PortScanner.refinedCategory(port: 5173, command: "redis-server") == .database)
        // A plain node server falls back to the port band.
        #expect(PortScanner.refinedCategory(port: 5173, command: "node") == .frontend)
    }
}
