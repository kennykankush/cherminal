# Changelog

All notable changes to Cherminal. Newest first.

## [Unreleased] — "Complete Overhaul" (2026-05-30)

A deep audit + bug-hunt + UI pass: two multi-agent audits and a bug-swarm,
every finding adversarially verified before fixing. Build green, 23 tests
(the test suite went from 0 → 23 this pass).

### Fixed — crashes & stability
- **Launch hang/deadlock.** Shell-env capture read its output *after*
  `waitUntilExit`, so a chatty `~/.zshrc` could fill the pipe and hang launch.
  Read stdout first, discard stderr, and capture off the launch thread.
- **NSTableView reentrancy crash.** Selecting/tapping a sidebar row mutated the
  list's own data mid-update. All row actions (select, tap, context menu, room
  expand/collapse, room auto-seed) now defer to the next runloop.
- **Crashes left no trace.** The signal handler used `malloc`/Foundation (not
  async-signal-safe), so a real fault wrote nothing. Rewrote it to be
  signal-safe (`backtrace_symbols_fd` + a pre-opened fd) and `dup2` stderr to a
  fault log so libghostty (Zig) panics are captured. Fault/debug logs rotate to
  `.prev` so a crash + relaunch keeps the evidence.
- **Subprocess deadlocks.** `lsof`/`grep`/login-shell stderr is now discarded so
  a full pipe can't wedge the child.
- **Spawn into a closing window.** The deferred surface spawn now re-checks the
  tab is still live before constructing a libghostty surface.

### Fixed — correctness & truth
- **Message count was wrong** (head/tail lower bound; Codex always "0"). Now the
  exact count from the full parse, hidden when it can't be trusted.
- **Context gauge over-reported after `/compact`** — stale cache tokens
  persisted and could even flip a 200K model into the 1M bucket. The latest
  turn's token components are now captured atomically.
- **Manual `/rename` was ignored** — the parser never read the `custom-title`
  record. It's now honored and takes precedence over the auto title.
- **Resumed tab could adopt a different same-room conversation.** Agent
  adoption is gated to shell tabs; resumed tabs keep a fixed identity; same-room
  adoptions are de-duplicated.
- **Port categorization:** the `port == 3001` backend rule was dead code
  (swallowed by the 3000–3099 frontend range); process name now overrides
  (postgres/redis/etc.) and command names aren't truncated.
- A complete single-line session file with no trailing newline is now parsed.
- Codex gauge can no longer read over-full ("260k / 256k").
- Codex last-active time reads a 64KB tail (was 8KB) so recently-used sessions
  don't sink in Recent.
- `--resume <id>` is validated against the UUID alphabet before interpolation.

### Fixed — leaks & lifecycle
- **Dev-server port poll** no longer leaks (ran forever if a window closed
  without `onDisappear`); polling is driven off tab count + inspector
  visibility, deterministically.
- **"Your turn" attention set** (`awaitingTurnIDs`) is cleared on tab close and
  identity flip (was insert-on-bell / remove-on-focus only).
- Coordinator notification observers are removed in `deinit`.
- Reused-PID mislabel in the live-linker guarded (pid must map to the same
  controller before and after the `lsof`).
- The shared `SessionCache` batch transaction uses a depth counter so the two
  concurrent scanners can't commit each other's in-flight rows early.

### Added
- **Tab keyboard shortcuts:** ⌘T new tab, ⌘1–8 select, ⌘9 last, ⌘⇧] / ⌘⇧[
  next/prev — via a local key monitor (SwiftUI `.commands` don't route in this
  AppKit-windowed app).
- **"Your turn" attention light** — a calm blue ambient signal (slow breathe,
  Reduce-Motion aware) when an agent finishes its turn; clears on focus; agent
  tabs only. Driven by the conversation's own session JSONL (Claude
  `stop_reason: end_turn`, Codex `task_complete`) via **FSEvents** — no terminal
  bell, no injected hooks, no polling (observe-externally). Lights within ~0.3s.
- **Session restore** — quitting persists the open tabs; the next launch reopens
  them in order. Agents resume (`claude --resume` / `codex resume`) with the
  right session file (restored after the cache snapshot so the context gauge
  works); shells reopen in their room; a vanished session falls back to a shell.
  Shell-only/empty sessions still open instantly.
- **Coffee button** — a one-click "keep this Mac awake" toggle (`caffeinate -di`,
  mirroring the `goodnight` alias) in the chat pane's top-right utility cluster,
  beside the Context toggle. The child process ends when Cherminal quits.
- **Right-click → Pin/Unpin** on any conversation row.
- **Drop to a shell** when a resumed agent exits, instead of Ghostty's
  "Process exited. Press any key to close."
- New app icon (Icon-iOS-Dark artwork).
- A Swift Testing target (0 → 23 tests): session parsing, usage math, cache
  round-trips, path/port logic, lsof parsing.

### Changed — UI
- **Inspector restructured into one calm Context surface** — the gauge is
  visible on open, no mode-switching. The old 4-tab control is gone:
  - **Pin** → a glyph in the Context header + a "Pinned" section at the top of
    the sidebar (pinned conversations are lifted out of the main list, not
    duplicated).
  - **Groups** → a menu-bar "Groups" menu (Save / Open / Delete), placed
    locale-safely.
  - **Ports** → an ambient footer ("N dev servers", nothing when zero).
- **Calmer context gauge:** neutral below 75%, clay accent 75–90%, a muted red
  only at 90%+ (was a green/orange/red traffic light).
- **Sidebar mode + inspector visibility are app-wide and persisted** (were
  per-window, so they looked random); default sidebar mode is now **Recent**.
- Design-token system wired up (dead tokens removed; calm palette added).

### Performance
- First window opens immediately instead of waiting for the full session scan.
- Surface config is built off the main thread (no up-to-3s cold-launch freeze).
- `SessionCache` reuses one prepared statement and batches a scan's writes into
  a single transaction (~880 statement compiles + ~880 WAL commits → ~0 + 1).
- `PathEncoder.decode` memoized (and no longer caches a lossy fallback).
- Live-linker `lsof` poll backed off 3s → 8s.
- Room grouping memoized; per-row/line/log formatters hoisted to statics.
- Context-window gauge folds in only appended bytes instead of re-reading the
  whole session each poll.
- Full-text search candidates sorted by recency before the result cap.

### Internal
- Claude + Codex scanners unified onto one `SessionScanEngine`.
- Removed the unwired "continue where you left off" session-restore code.
- Removed an NSTableView-reentrancy-prone synchronous mutation pattern across
  every sidebar interaction.

> Note: this entry is committed but not yet shipped to the installed app at the
> time of writing.

## [0.1.1]
- Baseline prior to the overhaul: sidebar of Claude Code / Codex conversations,
  native tabs, context/pin/group/port inspector, full-text search, dev-server
  port watcher.
