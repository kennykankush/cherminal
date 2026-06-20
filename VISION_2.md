# Cherminal v2 — The Project Canvas

> **v1 was the rail. v2 is the canvas.** Instead of conversations stacked in a
> grid behind tabs, each project is a *spatial canvas* you arrange, zoom around,
> and live inside — terminals, the running app, the mobile view, notes — every
> agent and everything it's building, on one smooth surface.

This supersedes parts of [`VISION.md`](VISION.md) (the grid/tabs middle pane,
the "no embedded browser / no nested hierarchy" wall). **`VISION.md` stays as the
v1 record — do not rewrite it.** What still holds from v1 is called out below.

Born 2026-06-19 from "turn Belvedere into a cnvs.dev kind of canvas." Reference
products: **cnvs.dev** ("command an army of agents," closed) and **Maestri** ("an
infinite canvas where coding agents work in concert," native SwiftUI + a custom
canvas engine) — the open sibling we reason from.

---

## The Shift

| v1 (rail) | v2 (canvas) |
|-----------|-------------|
| Conversations in a sidebar, one agent in the middle | A **spatial canvas** per project, many nodes placed freely |
| Equal-split grid + native tabs | **Freeform floating frames** — drag, resize, stack, zoom |
| Middle pane = a terminal | Nodes = terminal **or browser, phone, notes…** |
| Switch tabs | **Switch canvases** (one per project) |
| "Observe agents, never inject" | Still true — for the *agent* nodes |

The canvas is not an IDE and not just a terminal multiplexer. It's the **whole
working surface of one project**: the agents building it *and* the thing being
built, side by side, in space. That's the line past cnvs.dev — cnvs is an army of
agents; this is the project's entire cockpit.

---

## Primitives

- **Canvas** = a **workspace = a room** (`~/dev/fantopy-hadi`, `~/dev/<project>`).
  One spatial board per project, remembering its own layout. Your rooms concept,
  unchanged — the left sidebar becomes the **canvas switcher**. Pick a project →
  its canvas opens → arrange your cockpit → switch project → a different canvas.
- **Node** = a frame on the canvas. Free position + size, draggable, resizable,
  zoomable, stackable. Types:
  - **terminal** — an agent (Claude/Codex) or shell. The core node.
  - **browser** — the localhost / app being built, live.
  - **phone** — the mobile view (see Open Questions for what "phone" means).
  - **note / reference** — markdown, sketches, links.
- **The Node abstraction** (load-bearing): every node type knows how to
  **go live · freeze · snapshot · report size**. The canvas engine doesn't care
  what's inside a node — terminal/browser/phone are just conformances. This is
  what keeps it both *smooth* and *open-ended*.

---

## The One Load-Bearing Rule: SMOOTH

> v1's rule was "observe, never inject." v2's rule is **the canvas must be
> buttery — pan, zoom, and arrange at 120fps, always.** cnvs.dev's whole magic is
> that it *feels* effortless. If a feature makes the canvas stutter, it doesn't
> ship that way.

We proved the recipe with a real spike (branch `spike/canvas-perf`,
2026-06-19 — real Ghostty surfaces, streaming, auto-panning):

- **The engine is AppKit + Core Animation — never SwiftUI for the plane of
  nodes.** SwiftUI is for chrome only. (The archived v2 deck lagged precisely
  because it was a SwiftUI ZStack of live-surface cards with `.ultraThinMaterial`
  blur over live terminals + per-card clip/shadow + whole-tree re-renders on
  every status tick. None of that was Ghostty's fault.)
- **Only a bounded handful of nodes are ever LIVE** (≈ the focused one + a small
  ring). Everything else is a **frozen snapshot** or a cheap card. The spike held
  the live count at **8 regardless of total nodes** (8 / 16 / 32 / 64).
- **Bounded live = bounded cost.** 64 nodes with culling on: **8 live, ~234 MB,
  ~120–130 fps at rest.** 64 nodes with culling *off* (the v1 "everything live"):
  **64 live, ~1.2 GB, stutter.** Culling is the whole game.
- **Freeze everything during motion.** While you're panning/zooming, *nothing*
  spawns or re-renders live — it's all snapshots; live resumes when motion
  settles. (Figma/tldraw do exactly this.)
- **Thaw via dtach, not cold spawn** (the crown jewel from v1). A culled terminal
  keeps running headless under its dtach master; bringing it back *reattaches* a
  surface instead of cold-spawning one. The spike's pan-time hitches at 32–64
  nodes came from cold-spawning + a slow synchronous snapshot on the main
  thread — both removed by freeze-on-motion + dtach reattach + a warm ring.

Per-node-type live/freeze strategy (different physics each):
- **terminal** → Metal surface, cheap-ish; freeze via an **IOSurface from
  Ghostty's renderer** (a small libghostty-side hook — the cheap CG-path capture
  `cacheDisplay` was ~27ms and didn't capture Metal glyphs); thaw via dtach.
- **browser** → `WKWebView`, heavy (own process, live JS), but trivially
  freezable (`takeSnapshot` → image). Live only when focused.
- **phone** → strategy depends on what "phone" is (Open Questions).

---

## What Carries Over From v1 (still true)

- **Observe agents externally, never inject** — for terminal/agent nodes. No
  hooks, no wrapper, no env injection. Read session files + inspect processes.
- **dtach persistence** — every terminal survives quit/relaunch; now it *also*
  powers canvas freeze/thaw. The `ConversationLedger` laws, `ProcTable`,
  `AttentionLaw`, the whole foundation pass stay.
- **Rooms** = `~/dev/*`. The canvas is per-room.
- **Calm, personal, built for Hadi.** No notification storms. No settings-UI
  sprawl. One user.
- **The pure-law / extract-and-test house style** (see [`MAP.md`](MAP.md)).

---

## The New Wall (so v2 doesn't re-bloat)

- ❌ No SwiftUI in the canvas hot path. Chrome only.
- ❌ No node that can't define live/freeze/snapshot/size — every type fits the
  abstraction or it doesn't go on the canvas.
- ❌ No unbounded live nodes. The live budget is sacred; if it's not live, it's a
  snapshot.
- ❌ No re-render of the plane on background status ticks (the v1-deck mistake).
- ❌ Still not an IDE. Nodes are *things you watch and talk to*, not a file tree.

---

## Open Questions (the live forks)

1. **Zoom** — *leaning: true infinite zoomable canvas* (zoom out to see the whole
   project, zoom into one terminal full-bleed) like cnvs.dev. Alternative: a fixed
   "board" you arrange windows on without real zoom (simpler engine).
2. **"Phone" node** — *leaning: responsive web preview at phone size first*
   (cheap, smooth). Heavier later options: a device **mirror**, or a real iOS
   **simulator** (very heavy — realistically one live ever).
3. **Canvas scope** — *leaning: one canvas per `~/dev` project*, possibly plus
   **ad-hoc** canvases you name freely.
4. **Voice** — cnvs.dev's headline ("command with your voice"). Adopt, or skip
   for now? (Currently out of scope.)
5. **Agent-to-agent wiring** — Maestri lets you draw a line between two agent
   nodes so they talk (PTY orchestration). Tempting; deferred.

---

## Proven / Next Probes

- ✅ AppKit/CA canvas + culling + naked surfaces holds 120fps with bounded live
  count and RAM (spike, 2026-06-19).
- ⏳ Pan-time smoothness on the *real* design (freeze-on-motion + dtach reattach +
  warm ring) — measure next.
- ⏳ Cheap, faithful terminal snapshot via Ghostty IOSurface — design + validate.
- ⏳ Browser node cost + `takeSnapshot` freeze fidelity.

---

## Build Sequence (proposed)

1. **VISION_2** (this doc).
2. **Canvas engine kernel** on a v2 branch — AppKit/CA canvas, the Node
   abstraction, culling + LOD + freeze-on-motion, dtach-backed terminal thaw.
   Terminals only. Prove buttery pan/zoom on the real design.
3. **Canvas = room + switcher + persistence** — wire canvases to rooms, sidebar
   becomes the switcher, persist per-canvas layout (reuse the archived `DeckFrame`
   geometry + persistence — that work survives).
4. **Node types** — browser (`WKWebView` + snapshot), then phone.
5. **The pivot** — canvas becomes the primary surface; retire the v1 tab grid.
