# Cherminal

[![CI](https://github.com/kennykankush/cherminal/actions/workflows/ci.yml/badge.svg)](https://github.com/kennykankush/cherminal/actions/workflows/ci.yml)

> **chat + terminal** — the room you enter to see every AI conversation across your `~/dev` rooms, and jump back into any one.

Cherminal is a personal macOS app: a calm, room-driven manager for living with CLI AI agents (Claude Code, Codex). It's the ChatGPT/Claude three-pane layout retargeted at the terminal — a **conversations rail** on the left, a real **Ghostty terminal grid** in the middle, and a **context + live-fleet inspector** on the right (usage, git, and a status minimap).

It's built for one user and one workflow. See **[VISION.md](VISION.md)** for the *why*, the primitives, and the non-goals.

## The load-bearing rule

> **Observe externally. Never inject.**

Cherminal watches agents the way a window manager watches windows — by reading the OS, never by injecting into the agent. **No hooks, no wrapper binary, no env injection.** It reads Claude/Codex session files and matches running processes by PID → cwd. If a feature requires injecting into the agent, it doesn't ship.

## What it does

- **Three-pane room.** Conversations sidebar (rooms, full-text search, pins, saved tab groups) · a real Ghostty **terminal grid** (split a tab into up to 16 panes) · a right inspector with **Details** and **Sessions** tabs.
- **Live agent state, observed externally.** By tailing the session JSONL (no hooks), Cherminal knows whether each agent is *working*, *waiting on you* ("your turn"), or idle — surfaced as a calm blue light in the sidebar and a **quick-look minimap** (Sessions tab) that mirrors every tab's pane grid and pulses each cell by state: **blue = done**, **sweeping bar = working**, ring = active pane. Click a cell to jump there.
- **Finish alerts.** A macOS notification + Dock badge the moment an agent finishes in a pane you're *not* watching (tap to jump). **⌘⇧J** cycles focus to the next agent waiting on you.
- **Burst detection.** When an agent hits its account usage limit, its panes go red (**"CODEX BURST"**) and the Details tab shows the limit banner.
- **Details readout.** Context-window fill, token breakdown, 5h/Weekly usage-limit meters, dev-server ports — plus **live git state** for the room (branch, ahead/behind, ±diff, changed files), read-only.
- **Persistent sessions.** Every pane runs under `dtach` (on by default), so agents — including ones you hand-launch by typing `claude` in any tab — survive quit/relaunch and pane-close (parked + reattachable); the full pane-grid layout restores on launch and live masters reattach to the same processes. Opt out with `defaults write dev.hamulia.Cherminal cherminal.persistentSessions -bool false`.

## Requirements

- **Apple Silicon Mac (arm64).** The app is arm64-only (the vendored libghostty is arm64-only).
- **macOS 26+** (deployment target).
- **Xcode 26+**.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`. The `.xcodeproj` is generated from `project.yml`.
- `vendor/GhosttyKit.xcframework` (libghostty) is committed — no separate Ghostty build is needed for normal app work.

## Build & run

The Xcode project is generated; regenerate it after pulling or editing `project.yml`:

```sh
xcodegen generate
```

One target produces two products:

| Config | Product | Bundle id | Use |
|---|---|---|---|
| **Debug** | `CherminalDev.app` | `dev.hamulia.Cherminal.dev` | iterate — separate data dir & Dock entry, safe to run *alongside* the daily driver |
| **Release** | `Cherminal.app` | `dev.hamulia.Cherminal` | the installed daily driver |

### Iterate (dev build)

```sh
xcodebuild -project Cherminal.xcodeproj -scheme Cherminal -configuration Debug \
  -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
open -n build/Build/Products/Debug/CherminalDev.app
```

CherminalDev is fully independent of the installed Cherminal — its own session, its own `dtach` sockets — so you can test without disturbing your daily driver.

### Install / update the daily driver

```sh
scripts/install.sh
```

Builds Release (arm64), then does a **session-safe in-place swap** into `/Applications/Cherminal.app`. It does **not** quit a running copy — so it's safe to run from inside a Cherminal pane. **Quit & reopen** Cherminal (⌘Q, then relaunch) to pick up the new build; your tabs and `dtach` agents restore on relaunch.

## Architecture

A SwiftUI app embedding **libghostty** (vendored as `GhosttyKit.xcframework`). Windows are native macOS tabs: one `NSWindow` per tab, joined in one tab group, each hosting the full three-pane SwiftUI. Shared services live on `AppEnvironment.shared`.

```
Cherminal/
├── CherminalApp.swift        @main · lifecycle · ghostty_init · GHOSTTY_RESOURCES_DIR · tab shortcuts
├── Terminal/
│   ├── NativeTabs/           TabWindowCoordinator (tab group, lifecycle, live-state reconcile)
│   ├── Grid/                 Workspace / Pane model + the split-pane grid view
│   ├── Dtach.swift           persistent-session wrapper (master via lsof on the socket)
│   ├── TurnState.swift       working / "your turn" detection from the session JSONL
│   ├── LiveSessionLinker.swift  lsof: PID → open session file / cwd (see through dtach)
│   ├── FleetAlerts.swift     finish notification + Dock badge + burst detection
│   ├── TerminalCommand.swift builds the resume command + surface config per conversation
│   └── BinaryResolver.swift  captures the login-shell PATH/env so bare commands resolve
├── Discovery/                read-only discovery: ConversationRegistry, Claude/Codex scanners,
│                             SessionCache, GitStatusReader, ClaudeRateLimits, ports, FS watcher
├── Context/                  right pane: Details (usage / limits / ports / git) + Sessions (minimap)
├── Sidebar/                  left pane: conversation list
├── Vendor/Ghostty/           vendored Ghostty Swift hosting layer (Surface View, App, Config, Input)
├── Diagnostics.swift         crash/fault capture
└── Diagnostics/Metrics.swift optional headless perf CSV
Resources/ghostty/terminfo    bundled xterm-ghostty terminfo (see Gotchas)
vendor/GhosttyKit.xcframework libghostty
```

### Sessions, live state & the detach tray

- **Discovery is read-only:** it scans `~/.claude/projects/` and `~/.codex/sessions/`, and links running `claude`/`codex` processes via `lsof`/cwd. No hooks.
- **Seeing through `dtach`:** a resumed agent runs under a daemonized `dtach` master, so the surface's foreground process is the `login`/dtach-client wrapper, not the agent. Liveness resolves the real process by `lsof`-ing the **socket file** (macOS `pgrep` can't see the daemonized master). Codex forks a new rollout on resume, so usage/turn detection follows the file it's actually writing.
- **Turn state, no hooks:** `TurnState` tails the session JSONL — Claude's `stop_reason`, Codex's `task_complete` — to decide *working / your turn / idle*, driven by FSEvents (~0.3s). `ClaudeRateLimits` adds the 5h/Weekly meters from the OAuth usage API (the one deliberate network call); `BurstDetector` reads the pane's visible terminal text for an account usage-limit banner.
- **Resumed agents survive teardown** (app quit, pane close). Closing an agent pane *parks* it — its `dtach` master stays alive — and reopening reattaches it; parked agents show in the **Sessions** tab for one-click reattach. Sockets live in `~/.cherminal/dtach/<bundle-id>/`.

## Gotchas worth knowing

- **arm64-only.** `libghostty-internal-fat.a` is arm64-only, so Release must pin `ARCHS=arm64` (set in `project.yml`); a universal/x86_64 link fails.
- **Bundled terminfo + `GHOSTTY_RESOURCES_DIR`.** libghostty finds its terminfo via `GHOSTTY_RESOURCES_DIR`. Cherminal bundles `Resources/ghostty/terminfo` and points that env var at it before `ghostty_init`. Without it, libghostty falls back to `TERM=xterm-256color`, which breaks bracketed paste (multi-line paste into agent TUIs) and the kitty keyboard protocol (Shift+Enter). If you bump the vendored Ghostty, refresh this terminfo from the matching `Ghostty.app/Contents/Resources/terminfo`.
- **`scripts/install.sh` is session-safe.** It swaps the bundle in place without quitting, because the session is often run *inside* the daily driver — quitting it would kill the installer.
- **`as? AppDelegate` casts in the vendored Ghostty layer always return nil** in Cherminal (different app-delegate class), so features routed through that cast silently no-op. Source app state from `AppEnvironment` instead.

## Diagnostics

- Crash/fault capture starts at launch (`Diagnostics.bootstrap()`).
- Optional headless perf CSV: `defaults write dev.hamulia.Cherminal cherminal.metrics -bool true` → samples to `~/.cherminal/metrics.csv` (off by default).

## Docs

- **[VISION.md](VISION.md)** — what Cherminal is, the load-bearing rule, the non-goals (the wall).
- **[CHANGELOG.md](CHANGELOG.md)**
- `ROADMAP.md` (local; not tracked)

## Status

A personal, single-user tool, tightly coupled to one stack (Claude Code, Codex, Ghostty, `~/dev/*`). Not packaged for general distribution.
