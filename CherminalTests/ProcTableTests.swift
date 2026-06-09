import Testing
import Foundation
@testable import Cherminal

struct ProcTableTests {
    private let dir = "/Users/me/.cherminal/dtach/dev.hamulia.Cherminal"

    /// Real-world shape: a master holds its socket on TWO fds (listener +
    /// accepted client connection) — must dedup to one pid; paths outside our
    /// dtach dir are ignored.
    @Test func lsofParseDedupsAndScopes() {
        let raw = """
        p4093
        cdtach
        f3
        n/Users/me/.cherminal/dtach/dev.hamulia.Cherminal/aaa.sock
        f5
        n/Users/me/.cherminal/dtach/dev.hamulia.Cherminal/aaa.sock
        p500
        cdtach
        f3
        n/Users/me/.cherminal/dtach/dev.hamulia.Cherminal/bbb.sock
        p600
        cSpotify
        f7
        n/private/tmp/com.spotify.sock
        """
        let holders = ProcTable.parseLsofUnixSockets(raw, underDirectory: dir)
        #expect(holders["\(dir)/aaa.sock"] == [4093])
        #expect(holders["\(dir)/bbb.sock"] == [500])
        #expect(holders.count == 2)   // Spotify's socket is out of scope
    }

    /// ps columns are right-aligned with space padding; tpgid can be 0 (a
    /// daemonized master has no controlling terminal); argv[0] may start with
    /// "-" (login process) and contain spaces — all must survive parsing.
    @Test func psParseHandlesPaddingDashesAndSpaces() {
        let raw = """
            4093  4092     0 -/Applications/Cherminal.app/Contents/MacOS/dtach -A /tmp/x.sock -z /bin/sh -c claude --resume abc-123
              77     1   500 /usr/libexec/something
           88888 77777 88888 node /Users/me/dev/my app/server.js
        """
        let ps = ProcTable.parsePS(raw)
        #expect(ps.parent[4093] == 4092)
        #expect(ps.tpgid[4093] == nil)              // 0 → no foreground group
        #expect(ps.tpgid[77] == 500)
        #expect(ps.parent[88888] == 77777)
        #expect(ps.children[77777] == [88888])
        #expect(ps.argv[4093]?.hasPrefix("-/Applications") == true)
        #expect(ps.argv[88888] == "node /Users/me/dev/my app/server.js")
    }

    /// The master-vs-client law: with two holders, the one WITH a child is the
    /// master (the client is a childless relay); single holder is the master.
    @Test func masterResolutionPrefersHolderWithChild() {
        let table = ProcTable(
            socketHolders: ["\(Dtach.directory.path)/multi.sock": [900, 901],
                            "\(Dtach.directory.path)/single.sock": [950]],
            parent: [:],
            childrenByParent: [901: [902]],   // 901 has the inner shell → master
            tpgid: [:],
            argv: [:])
        #expect(Dtach.masterPID(id: "multi", table: table) == 901)
        #expect(Dtach.masterPID(id: "single", table: table) == 950)
        #expect(Dtach.masterPID(id: "absent", table: table) == nil)
    }

    /// Inner-foreground law: master → inner shell child → that pty's
    /// foreground group leader (the hand-launched agent); shell pid when at a
    /// prompt; master pid when no child resolved yet.
    @Test func innerForegroundFollowsTpgid() {
        let sock = "\(Dtach.directory.path)/x.sock"
        let busy = ProcTable(socketHolders: [sock: [10]], parent: [:],
                             childrenByParent: [10: [11]], tpgid: [11: 42], argv: [:])
        #expect(Dtach.innerForegroundPID(id: "x", table: busy) == 42)

        let atPrompt = ProcTable(socketHolders: [sock: [10]], parent: [:],
                                 childrenByParent: [10: [11]], tpgid: [:], argv: [:])
        #expect(Dtach.innerForegroundPID(id: "x", table: atPrompt) == 11)

        let bare = ProcTable(socketHolders: [sock: [10]], parent: [:],
                             childrenByParent: [:], tpgid: [:], argv: [:])
        #expect(Dtach.innerForegroundPID(id: "x", table: bare) == 10)
    }

    /// Liveness from the snapshot: present holders = alive, absent = dead.
    @Test func livenessFromTable() {
        let sock = "\(Dtach.directory.path)/live.sock"
        let table = ProcTable(socketHolders: [sock: [7]], parent: [:],
                              childrenByParent: [:], tpgid: [:], argv: [:])
        #expect(Dtach.isMasterAlive(id: "live", table: table))
        #expect(!Dtach.isMasterAlive(id: "gone", table: table))
    }
}
