import SwiftUI

/// A spawned sub-agent of a Claude session. Claude writes each Task/agent it
/// spawns to its own transcript under `<session>/<id>/subagents/agent-*.jsonl`,
/// so we can see them purely from the filesystem — no process hooks.
struct SpawnedAgent: Identifiable, Equatable {
    let id: String          // agent-<hash>
    let state: PetState
    let lastActivity: Date
}

enum PetState: Equatable { case working, done }

/// Lists the sub-agents a Claude conversation has spawned and derives a coarse
/// state from each transcript's recency (sub-agents stop writing once finished).
/// Codex has no per-sub-agent transcript, so this is Claude-only.
enum SpawnedAgentScanner {
    static func scan(for convo: Conversation) -> [SpawnedAgent] {
        guard convo.agent == .claudeCode else { return [] }
        // <room>/<id>.jsonl → <room>/<id>/subagents/. Primary path: derive from
        // the tracked session file. Fallback: the session id is globally unique,
        // so if the tracked room is wrong (cwd/room mismatch on adoption), find
        // the subagents dir by id under any project room.
        let fm = FileManager.default
        var dir = convo.sessionFile.deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), let alt = locateByID(convo.id) {
            dir = alt
        }
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let now = Date()
        return files.compactMap { url -> SpawnedAgent? in
            guard url.pathExtension == "jsonl" else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // A sub-agent still writing in the last ~12s is "working"; once it
            // finishes it stops touching its file.
            let state: PetState = now.timeIntervalSince(mtime) < 12 ? .working : .done
            return SpawnedAgent(id: url.deletingPathExtension().lastPathComponent,
                                state: state, lastActivity: mtime)
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Locate `<projects>/<anyRoom>/<id>/subagents` by the (unique) session id,
    /// for when the tracked session file's room doesn't match where the agent
    /// actually writes (cwd/room mismatch on adoption).
    private static func locateByID(_ id: String) -> URL? {
        let fm = FileManager.default
        let projects = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let rooms = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return nil }
        for room in rooms {
            let candidate = room.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// The pixel-art Claude Code mascot ("Clawd"), drawn from a tiny bitmap so it
/// scales crisply and tints by state. 0 = empty, 1 = body, 2 = eye.
struct ClawdSprite: View {
    var tint: SwiftUI.Color
    var pixel: CGFloat = 4

    // Traced from the real Clawd mascot: flat-top head, two black eyes, a wide
    // body band (arms out both sides), four stubby legs.
    private static let bitmap: [[Int]] = [
        [0,0,1,1,1,1,1,1,1,1,1,1,0,0],   // head
        [0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,2,2,1,1,1,1,2,2,1,0,0],   // eyes
        [0,0,1,2,2,1,1,1,1,2,2,1,0,0],
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1],   // body — arms poke out the sides
        [1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,1,0,1,0,0,0,1,0,1,0,0],   // four legs
    ]

    var body: some View {
        let cols = Self.bitmap[0].count, rows = Self.bitmap.count
        Canvas { ctx, size in
            let s = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
            let ox = (size.width - s * CGFloat(cols)) / 2
            let oy = (size.height - s * CGFloat(rows)) / 2
            for (r, row) in Self.bitmap.enumerated() {
                for (c, v) in row.enumerated() where v != 0 {
                    // +0.6 overlap closes hairline seams between blocks.
                    let rect = CGRect(x: ox + CGFloat(c) * s, y: oy + CGFloat(r) * s,
                                      width: s + 0.6, height: s + 0.6)
                    ctx.fill(Path(rect), with: .color(v == 2 ? .black : tint))
                }
            }
        }
        .frame(width: pixel * CGFloat(cols), height: pixel * CGFloat(rows))
        .accessibilityHidden(true)
    }
}

/// One small mascot in the field — tinted + gently breathing while its
/// sub-agent works, dimmed when finished. Status is in the hover tooltip so the
/// grid stays compact enough to fit ~30. (No persistent speech bubble — too
/// bulky at this size.)
struct ClawdPetCell: View {
    let agent: SpawnedAgent
    @State private var breathing = false

    var body: some View {
        ClawdSprite(tint: tint, pixel: 2.5)
            .opacity(agent.state == .done ? 0.5 : 1)
            .scaleEffect(agent.state == .working && breathing ? 1.08 : 1.0)
            .animation(agent.state == .working ? CHM.Motion.breathe : nil, value: breathing)
            .onAppear { breathing = true }
            .frame(maxWidth: .infinity)
            .help(status)
    }

    private var tint: SwiftUI.Color { agent.state == .working ? CHM.Color.accent : .secondary }

    /// A playful, deterministic verb per agent (no per-frame ticker — CPU-quiet)
    /// while working; "done!" when finished. Shown in the tooltip.
    private var status: String {
        guard agent.state == .working else { return "done!" }
        let verbs = ["working…", "thinking…", "cooking…", "crunching…", "digging…", "hatching…"]
        return verbs[abs(agent.id.hashValue) % verbs.count]
    }
}

/// The "field" of Clawd mascots — one per spawned sub-agent, wrapping into a
/// grid (fills across, then wraps), capped with a "+N more". Purely
/// presentational: the owning view (ContextWatchPane) scans on its always-
/// running task and passes the agents in. (Self-scanning here failed: a `.task`
/// on conditionally-empty content never fired, so `agents` never populated.)
struct ClawdPetsView: View {
    let agents: [SpawnedAgent]

    private let cap = 30
    private let columns = [GridItem(.adaptive(minimum: 40, maximum: 54), spacing: CHM.Space.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: CHM.Space.sm) {
            HStack(spacing: 5) {
                Text("Agents")
                    .font(CHM.Font.eyebrow).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.6)
                Text("\(workingCount) working")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: CHM.Space.sm) {
                ForEach(agents.prefix(cap)) { ClawdPetCell(agent: $0) }
            }
            if agents.count > cap {
                Text("+\(agents.count - cap) more")
                    .font(CHM.Font.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var workingCount: Int { agents.filter { $0.state == .working }.count }
}
