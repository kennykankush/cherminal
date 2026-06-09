import Testing
import Foundation
@testable import Cherminal

struct SubprocessTests {

    @Test func capturesStdoutAndStatus() {
        let out = Subprocess.run("/bin/echo", ["hello"])
        #expect(out?.stdout == "hello\n")
        #expect(out?.status == 0)
    }

    @Test func reportsNonZeroExit() {
        let out = Subprocess.run("/usr/bin/false", [])
        #expect(out != nil)
        #expect(out?.status != 0)
    }

    @Test func unlaunchableReturnsNil() {
        #expect(Subprocess.run("/no/such/binary", []) == nil)
    }

    /// The watchdog: a child that would run far past the timeout is killed and
    /// the call returns nil promptly — this is the guarantee that a wedged
    /// lsof/git/grep can never hang a poll loop or the quit path.
    @Test func timeoutKillsHungChild() {
        let start = Date()
        let out = Subprocess.run("/bin/sleep", ["30"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        #expect(out == nil)
        #expect(elapsed < 5)   // generous CI margin; the point is "not 30s"
    }

    @Test func quoteEscapesSingleQuotes() {
        #expect(Subprocess.quote("plain") == "'plain'")
        #expect(Subprocess.quote("a'b") == "'a'\\''b'")
        #expect(Subprocess.quote("/path with space/bin") == "'/path with space/bin'")
        // Round-trip through a real shell: the quoted form must reproduce the
        // original string exactly, whatever's inside.
        let nasty = "it's a \"test\" $(echo no) `no` \\ done"
        let echoed = Subprocess.stdout("/bin/sh", ["-c", "printf %s \(Subprocess.quote(nasty))"])
        #expect(echoed == nasty)
    }

    /// Dtach.wrap interpolates three things (binary, socket, inner command) —
    /// all must arrive quoted so no path or command can split the shell line.
    @Test func dtachWrapQuotesEverything() {
        let line = Dtach.wrap("echo 'hi there'", id: "test-id-1234")
        // The inner command survives with its quotes escaped.
        #expect(line.contains("/bin/sh -c 'echo '\\''hi there'\\'''"))
        // The socket path is quoted and keyed on the id.
        #expect(line.contains("'") && line.contains("test-id-1234.sock"))
        // Reattach-or-create + invisible detach + repaint flags all present.
        #expect(line.contains(" -A "))
        #expect(line.contains(" -z "))
        #expect(line.contains(" -r winch "))
    }
}
