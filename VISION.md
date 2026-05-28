# Cherminal

> **Cherminal**: chat + terminal. The room you enter to see every AI conversation across your rooms, and jump back into any one.

A room-driven Ghostty manager for living with AI agents. The room you enter to see all your other rooms.

---

## Origin

Born from a Warroom conversation on 2026-05-28.

Hadi was using `manaflow-ai/cmux` (v0.64.10) as his terminal + agent surface and increasingly feeling it was "too bloaty" — slow, notification-heavy, and meddling with Claude Code sessions. The bloat instinct was correct, with a specific mechanism:

cmux's Claude wrapper auto-injects hooks into Claude Code's hook system. Hooks fire on every event (each tool call, each message turn, each lifecycle event), and each fire = subprocess spawn + socket round-trip to the cmux daemon. That powers cmux's sidebar status, Feed approval queue, notification routing, and session restore — useful machinery, but it taxes every event in the agent's hot path. On top of that: background git status watcher, ports polling, embedded browser process(es), and the desktop app footprint. Three layers stacked on a workflow that uses none of what they enable.

The deeper realization: **cmux is built for async multi-agent coordination. Hadi's workflow is sync single-agent.** Different physics. cmux's strengths (The Feed, multi-agent ops, session restore, embedded browser) only pay off when orchestrating ≥3 agents at once. For one live conversation in one room at a time, cmux is a Mack truck commuting one block.

Hadi's actual workflow: organize work into "rooms" — folders under `~/dev/<project>` (currently ~48 of them). Start agent conversations by cd'ing into a room. With that many rooms, lose track of which conversations are alive in which rooms, and which dormant conversations are worth returning to.

The product is the claude.ai / chatgpt.com 3-pane layout retargeted at the CLI.

---

## Experience Promise

> "Open Cherminal, see every AI conversation you've started across your `~/dev` rooms, jump back into any one without losing your place."

Cherminal is the room you enter to see all your other rooms. You stand in it and look out.

It should feel:

- **Calm** — never spammy. No notification storms.
- **Always there** — the conversation rail is your home base.
- **Out of the way** — the agent never knows Cherminal exists. The middle pane is a plain Ghostty terminal.
- **Personal** — built for one user (Hadi), tightly coupled to his actual workflow.

---

## Product Shape

```
┌───────────────┬──────────────────────────────┬───────────────┐
│  CONVERSATIONS│                              │   CONTEXT     │
│               │       GHOSTTY TERMINAL       │   WATCH       │
│  by room      │       (the chat panel)       │               │
│  or recent    │                              │   live state  │
│               │                              │   of what's   │
│  click → load │                              │   happening   │
└───────────────┴──────────────────────────────┴───────────────┘
```

**Conversations on the left, agent in the middle, context watch on the right.** ChatGPT/Claude web UX, retargeted at the CLI.

Cherminal is **not an IDE**. An IDE's primitive is the file. Cherminal's primitive is the **conversation**. The agent does the file editing; Hadi navigates conversations. The 3-pane layout overlap with IDEs is superficial — it's the universal *list-of-things + active-thing + meta-about-active-thing* pattern that Slack, Linear, Notion, and ChatGPT all share.

---

## Architectural Rule (Load-Bearing)

> **Observe externally. Never inject.**

Cherminal watches agents the way a window manager watches windows — by looking at the OS, not by injecting into each app. This single rule is what separates Cherminal from cmux, and it's what keeps Cherminal fast.

Concretely:

- **No hooks** into Claude Code, Codex, or any other agent. Their hot path stays clean.
- **No wrapper binary.** Don't intercept the `claude` command.
- **No env injection.** Agents don't know Cherminal is running.
- **Read-only out-of-band observation only:**
  - Read Claude Code session files from `~/.claude/projects/<encoded-cwd>/`
  - Read Codex session history from its persistence dir
  - Enumerate Ghostty panes via Ghostty's IPC / CLI
  - Match `claude` / `codex` processes via PID → cwd
  - Watch the working tree (git status, file mtimes) for the active conversation's room

**If a feature requires injecting into the agent, it doesn't ship.**

---

## Primitives

- **Room** = a folder under `~/dev/*`. Hadi's existing methodology, untouched.
- **Conversation** = an agent process (claude / codex / etc.) bound to a room. States: *live* (running in a pane), *idle* (pane open, agent quiet), *dormant* (pane closed, session resumable from disk), *pinned* (user-marked as important).
- **Sidebar (left)** = flat list grouped by room. View modes: "recent across all rooms" or "scope to one room." Click → focus the Ghostty pane (or resume dormant).
- **Context watch (right)** = live state of the active conversation. v1 candidates: **files touched this turn + live git diff in the room**. Belongs to the live conversation, not the room as a whole.
- **Operations** = spawn / jump / list / pin / kill / resume. Nothing else.

---

## Non-Goals (The Wall)

These exist so future-Hadi can resist the temptation to re-bloat:

- ❌ No embedded browser
- ❌ No worktree management
- ❌ No approval queue / Feed
- ❌ No automation hooks / RPC server
- ❌ No notification spam (one notification surface, silent by default)
- ❌ No nested window / workspace / surface / pane hierarchy — flat rooms + conversations. **(Tabs reinstated 2026-05-28: a top tab bar above the terminal pane keeps multiple sessions alive concurrently. Original anti-tab stance was wrong for this workflow — switching conversations without killing the underlying agent process is the load-bearing UX. Tabs are flat: one row, no nesting.)**
- ❌ No "user settings" UI for everything — settings live in code or one JSON
- ❌ No general-purpose abstractions — hardcoded to Hadi's stack (Claude Code, Codex, Ghostty, `~/dev/*`)
- ❌ **No file tree, quick-edit, problems panel, or any other IDE-shaped feature.** Cherminal knows about *conversations*, not files. Files are the agent's job.

If a feature you're tempted to add isn't about conversations, don't add it.

---

## Build Direction — Decision Pending

Three options on the table. Pick before any code:

### A. Pure Ghostty splits + tiny TUI daemon  *(most disciplined)*

Leftmost Ghostty split runs a conversation-list TUI. Rightmost runs a context TUI. Middle is the agent. A small daemon (Rust / Go / Zig) watches session files, talks to Ghostty IPC, maps PIDs → cwd → agent. **Zero new app.**

- ✅ Minimal surface, observe-don't-inject enforced structurally, deletable in an afternoon
- ❌ Side panes look like terminals, not GUI sidebars — feel diverges from the mockup

### B. Native SwiftUI macOS app hosting libghostty  *(what cmux did, stripped)*

A real `Cherminal.app`. SwiftUI sidebars left and right, libghostty embedded in the middle.

- ✅ Matches the visual mockup exactly, native polish, GUI sidebars
- ❌ Architecturally identical to cmux v0.1 — full discipline burden on builder to never let it grow

### C. Menu bar app + global hotkey overlay + plain Ghostty  *(most Apple-y)*

No 3-pane window. Sidebar = Raycast-style command palette (`Cmd+Shift+Space` → conversation list). Context = menu bar dropdown that follows the frontmost Ghostty pane. Agent stays in plain Ghostty unchanged.

- ✅ Invisible until needed, doesn't fight existing habits, tiny footprint
- ❌ No always-on situational awareness for the right pane

**Recommended path:** build **A** first as a 1-week thesis test. If satisfying, ship as-is. If A's UX is unsatisfying, promote to **B** with knowledge of exactly what was missing. **C** is its own clean shape — worth a beat of thought before defaulting to A.

---

## Open Questions

- **Build direction**: A, B, or C? *(load-bearing)*
- **Right-pane content** beyond files + diff: activity feed? token state? pending input?
- **Conversation identity granularity**: every session a row, or latest-per-(room, agent), or only-pinned?
- **Sidebar host** if option B/C: separate window, menu bar, command palette overlay, or all three?
- **Multi-agent breadth** at v1: just Claude Code and Codex, or also Cursor / Gemini / Aider?
- **State persistence**: is the registry purely derived from session files + process inspection, or does Cherminal maintain its own state file for things like pins?

---

## First Workflow (Wedge)

The smallest serious thing that should work end-to-end:

1. Hadi opens Cherminal.
2. Left pane shows every Ghostty pane currently running `claude` or `codex`, grouped by their cwd's room name. Plus a section for recent dormant conversations (resumable from disk).
3. Hadi clicks a conversation → the corresponding Ghostty pane comes to focus.
4. Right pane shows files the active conversation has touched this turn + live git diff in that room.
5. From the conversation list, Hadi can spawn a new agent in a chosen room.

That's v0.1. Everything else waits.

---

## Origin Trail

Full thinking trail and birdwatch findings preserved in the Warroom:

- `/Users/hamulia/dev/warroom/research/belvedere/spark.md` — how the idea was born and what made it click
- `/Users/hamulia/dev/warroom/research/belvedere/birdwatch.md` — live evidence about cmux's injection mechanism

---

## Name

**Cherminal**: a portmanteau of **ch**at + t**erminal** — the two halves of what the app is. A conversations rail (chat) wrapped around a real Ghostty terminal. Plain-spoken and literal where the old name (Belvedere, "beautiful view") was evocative; the product is exactly what the name says. Renamed 2026-05-29.
