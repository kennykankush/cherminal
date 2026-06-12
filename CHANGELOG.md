# Changelog

All notable changes to Cherminal. Newest first.

## [Unreleased] — "The Details panel tells the truth" (2026-06-13)

### Fixed
- **Context gauge parity (the 3–4% gap).** The gauge measured against the
  raw model window; the agents don't. `ContextBudgetLaw` now mirrors each
  agent's own math — Claude (extracted from the installed binary): window −
  20k output reserve − 13k auto-compact buffer is the real ceiling (1M →
  967k); Codex (codex-rs): a 12k baseline off both numerator and
  denominator. The % now agrees with what the agent shows in the terminal,
  and the sub-line reads "X to auto-compact".
- **Stale CLAUDE/CODEX BURST.** The terminal-banner scrape is no longer the
  law: `BurstLaw` arbitrates it against authoritative account windows
  (Claude OAuth, now incl. active Opus/Sonnet weeklies; codex's in-file
  `rate_limit_reached_type`), and `RateWindowLaw` zeroes any window whose
  reset has passed — the red banner clears at the actual reset instead of
  living as long as the text sits in the viewport. Works in reverse too: a
  limit hit in a background session flags without any visible banner.
- **New chats no longer inherit the room's last conversation.** A fresh
  `claude` writes no session file until the first message, so the linker's
  cwd+recency fallback adopted the PREVIOUS conversation ("BELVEDERE FABLE
  on a brand-new chat"). ProcTable now carries process start times (`ps
  etime`); the ledger refuses to link a conversation last written before
  the process existed (`--continue` keeps pure recency — there the room's
  latest IS the selection). Until the first message, Details shows an
  honest **New conversation** state.
- **Harness noise is not your prompt.** `<task-notification>` records no
  longer show as "YOU: …" in Latest.
- **Dead-attach pane chain healed** — attach falls back to resume,
  close-surface requests close the pane, lost focus re-asserts on
  activation.
- **Rate-limit meters resilience** — keep-last-good bounded at 15 min (a
  429 storm reads as absent, not frozen); codex "premium" account shape
  survives; Claude's extra-usage spend surfaces ("$27.63 of $100").

### Added
- **Usage-limit notifications** (`UsageWatch` + `UsageAlertLaw`, pure and
  test-pinned): a window crossing 90% ("5h limit at 92% — resets in 1h
  04m"), a high window refreshing ("clear to run"), burst began/lifted
  (with reset countdown), and the active conversation's context window
  crossing 90% (fires once; re-arms below 75% after a compact).
- **Kill Pane (⌥⌘⇧W)** — end the process outright; close's ⌥ variant, no
  parking.
- **Homebrew tap lives in-repo** (`Casks/cherminal.rb`) — no separate
  homebrew-tap repo to keep in sync.

### Changed
- **Details panel rebuilt as cards.** Identity header (your name for the
  chat as the title, agent · workspace beneath, live status chip, pin); ONE
  Usage dashboard card (context gauge + account limit meters in a two-up
  grid + token totals behind a disclosure); a quieter Latest with quote
  bars; Workspace (branch, changes, path) and Session (one-line process
  vitals: "PID 18289 · 365 MB · 4.6%", dates, copy actions) merged cards.
  The burst banner counts down to its binding reset.

## [0.2.0] — build 5 (2026-06-11)

First signed + notarized release: one-command release pipeline (Developer
ID, notarization staple, strips the debugger entitlement plain xcodebuild
injects), three install modes (brew cask, curl installer, dmg), version
auto-bump incl. the in-repo cask. Bundles every "[Unreleased]" chapter
below, plus:

### Added
- **Pane zoom (⇧⌘↩)** — and grid cell identity follows the pane, not the
  slot.
- **Inspector knows the conversation** — Plan, Latest, Process, and copy
  actions (the foundation today's Details redesign builds on).

## "Hand-launched agents survive too" (2026-06-10, shipped in 0.2.0)

### Added
- **Background sessions in the sidebar.** A new **Background** section lists
  every claude session registered with the background-agent supervisor that
  isn't already open in a pane — headless dispatched agents and sessions
  running in other terminals — with live status (blue = blocked waiting on
  you, incl. the reason, e.g. "permission prompt"). Click to attach into a
  tab (`claude attach`; ^Z detaches, the session keeps running). Pure
  observation: one bounded `claude agents --json` poll every 15s, foreground
  only.
- **scripts/e2e-dtach.sh** — the dtach survival loop (foreign-socket
  reattach, same-pid across ⌘Q, wrap-by-default) as a one-command harness
  against the real dev app: 7 assertions, self-cleaning.

### Changed
- **Live-attach panes know who they are instantly.** A reattached
  hand-launched agent showed as "Terminal" for up to ~8s (and a sidebar click
  during that window could duplicate the session); restore now pre-adopts the
  persisted identity the moment the pane exists.
- **Workspace headers** carry live/awaiting status dots and show their git
  branch when expanded (fetched once, never polled); a quiet footer shows
  version + tab/parked counts.
- **Stricter concurrency checking** (`SWIFT_STRICT_CONCURRENCY: targeted`) —
  zero first-party diagnostics; latent actor-isolation bugs now surface at
  compile time.

### Changed
- **Sidebar revitalized (and the mode-switch stutter fixed).** Workspaces /
  Recent / Deep now share ONE persistent list whose content swaps instantly —
  each mode used to be its own table view, slid in/out with a move-transition
  that any mid-flight registry publish re-laid-out (the stutter), duplicated
  across every open tab. "Rooms" are now called **Workspaces** everywhere
  user-facing. Claude Code and Codex rows show their **real brand marks**
  (lobe-icons, vendored into the asset catalog) instead of stand-in symbols.
  New Claude-desktop-style "New Tab ⌘T" action row at the top; search results
  render in-list; the group-save row says "Save tabs as group" (workspaces
  are folders now — groups are tab sets).

### Added
- **Claude burst detection is live.** The exact banner family was extracted
  from the installed Claude Code binary (its composer is literally
  `` `You've hit your ${limit}` `` with session/weekly/Opus/Sonnet labels,
  plus a "usage limit reached — check plan" status variant) — no more waiting
  to observe a real burst. The "You're close to your usage limit"
  approaching-warning and transient "rate limited" deliberately do NOT trip.
  Pinned by tests.

### Changed
- **One FSEvents stream instead of two.** The registry (2.5s sidebar refresh)
  and the coordinator (~0.3s "your turn" light) now share a single kernel
  stream via a multi-subscriber `FilesystemWatcher` — each consumer keeps its
  own debounce + max-latency cadence, subscriptions attach/detach
  independently (integration-tested).
- **Sessions pane matured.** The minimap now follows the user's VISIBLE tab
  order (drag-reordering tabs reorders it; it used to follow open order), each
  tab row shows its ⌘n index + a proper frontmost/hover treatment, and both
  the minimap and the parked strip sit under consistent section headers.
  Right-click menus arrive: Jump Here / Close Pane on cells, Jump / Rename /
  Close Tab on rows. The state indicators were rebuilt on deterministic
  wall-clock phases (`CHM.Phase` + TimelineView): the working sweep is now a
  calm one-directional linear shimmer and the "done" glow a slow luminance
  breathe — the old `@State` + `repeatForever` versions restarted on every
  reconcile re-render, which is exactly the darting back-and-forth glitch.
  State flips crossfade (200ms) instead of popping. The sidebar's "your turn"
  light got the same deterministic fix.

### Added
- **Rename tabs.** Double-click a tab to edit its title inline (the vendored
  Ghostty tab-title editor, now wired up), or Tabs → Rename Tab (⌘⇧R; falls
  back to a prompt when the inline editor can't attach). Empty reverts to the
  automatic title (the active pane's room). The name persists with the
  workspace snapshot — it survives relaunch and travels with saved Groups —
  and wins over every automatic title write (adoption, reconcile) via the one
  title law (`refreshTitle`). The Sessions minimap shows it live too.
- **Persistent sessions ON by default.** Every pane — shells included — now
  runs under a `dtach` master (a registered default; `defaults write
  dev.hamulia.Cherminal cherminal.persistentSessions -bool false` opts out).
- **Hand-launched agents survive ⌘Q.** A `claude`/`codex` you type into any
  tab used to run raw inside the shell: the conversation came back on
  relaunch, but as a cold `--resume` — process killed, in-flight turn lost.
  Now the pane's real socket identity (its wrapped shell's) is persisted when
  it differs from the conversation id, the launch sweep keeps that master
  alive, and restore **reattaches the live process** (the identity re-adopts
  within seconds); if the master died (Mac restart), it falls back to the cold
  `--resume` exactly as before. Sidebar-opened and hand-launched conversations
  now have the same survival guarantee. Live-tested E2E (quit → master
  survives → relaunch → same pid reattached).

## "The foundation pass" (2026-06-10, shipped in 0.2.0)

A first-principles strengthening of the bank logic — who owns which
conversation, in which pane, on which socket — plus a large cut in standing
cost. No feature changes; the same app on much firmer ground.

### Changed (foundations)
- **ConversationLedger.** The identity law — open-pane preference (opened-as
  beats adopted), the unique serialization claim, restore dedup, tray
  park/restore guards, the launch-sweep keep-set — used to be re-derived at six
  coordinator sites with slightly different rules. It now lives once, as pure
  unit-tested functions; the coordinator delegates.
- **AppPhase.** One lifecycle state machine (launching → running ⇄ quitDeciding
  → terminating) replaces the `isTerminating`/`terminationDecisionPending`
  boolean pair. Closes two launch races: the debounced persist can no longer
  clobber the saved session mid-restore, and a tab opened in the first seconds
  after launch no longer cancels the restore (restore is now idempotent —
  already-open conversations are skipped).
- **ProcTable.** All process liveness (dtach masters, parent/child trees, pty
  foreground groups, argv) is answered from ONE snapshot — two bounded spawns
  (~30 ms each, TTL-shared) — instead of lsof+pgrep+ps *per pane per tick*
  (~3N+2 spawns). A failed snapshot reads as "unknown", never "everything died".
- **Watchdog-bounded subprocesses.** Every probe (lsof/ps/pgrep/git/grep/login
  shell) is SIGKILLed at a timeout — a probe wedged on a dead mount can no
  longer hang a poll loop or the quit path. Binary paths in spawned commands
  are now fully quoted.
- **Incremental discovery.** A session write now refreshes just that file —
  the watcher passes FSEvents' changed paths through (classified to exactly
  what the scanners enumerate; subagent sidechain files are correctly ignored)
  instead of triggering a full stat-sweep of every session. The debounce gained
  a max-latency bound, so a long continuous turn can't starve the sidebar or
  the "your turn" light.
- **Groups save full grids.** "Save this workspace" now saves every pane of
  every tab (it captured only each tab's active pane); old single-pane groups
  migrate on decode, and groups reopen through the same idempotent restore path
  as session restore — fully-open tabs focus instead of duplicating.
- **Inspector polling is visibility-gated.** The per-tab usage/git loops run
  only for the tab actually on screen (they ran for every open tab).
- **TurnState verified against real data.** Claude: sidechains live in separate
  files and cannot pollute the light (documented + fixture-pinned). Codex: the
  scan now skips bookkeeping trailers so a write-order change can't kill it.

### Fixed
- Quitting mid-launch no longer persists a partially-restored tab set.
- Closing a multi-pane window cleans the attention/seen state for every pane
  (the holder-only cleanup leaked the others').
- The metrics "surfaces" leak-tripwire column read a dead counter key since the
  Pane rename (always 0); BinaryResolver retries a failed login-shell capture
  and no longer caches failed lookups; full-text search streams files instead
  of loading them whole.

### Removed
- `Conversation.state` and `messageCount` (model fields nothing trusted),
  persisted-but-ignored snapshot fields (layout/gridPosition/socketID), the V1
  single-pane group path (`snapshot()`/`openPersistedTabs`), and stale
  comments/docs that misdescribed the system.

### Tests
- 23 → 60: the ledger's invariants, ProcTable parsers, subprocess watchdog,
  dtach quoting, TurnState fixtures, persisted-shape migrations, path
  classification.

## "Persistent sessions & live fleet awareness" (2026-06-09, shipped in 0.2.0)

Agents now survive across launches, and Cherminal surfaces what every one of
them is doing at a glance — a status minimap, finish alerts, and per-room git —
all observe-externally (no hooks, no injection).

### Added
- **Persistent sessions (`dtach`).** Agents run under a bundled `dtach`, so they
  survive app quit/relaunch and pane close: closing an agent pane *parks* it
  (its master stays alive) and reopening reattaches the same master. The full
  pane-grid layout restores on launch. The `dtach` binary is bundled into the app
  (no Homebrew dependency; GPL source vendored). Live 1:1 *dtach-everything*
  (wrap shells too) is behind `cherminal.persistentSessions` (default off).
- **Pane grid.** Split a tab into an N-pane grid (up to 16), equal-split, re-fit
  as panes are added/removed.
- **Quick-look minimap (Sessions inspector tab).** Every open tab rendered as a
  small grid mirroring its real pane layout; each cell pulses by live state —
  **blue = done / your turn**, **sweeping bar = working**, ring = active pane —
  click a cell to jump there. A compact **Parked** strip reattaches closed agents.
- **Finish alerts.** macOS notification + Dock badge the moment an agent finishes
  in a pane you're *not* watching (tap to jump); shown even while the app is
  frontmost, suppressed for the pane on screen.
- **⌘⇧J — Jump to Next Waiting Agent**, cycling focus across all tabs/panes.
- **Agent "burst" detection.** When an agent hits its account usage limit, its
  panes go red (**"CODEX BURST"**) and the Details tab shows the limit banner —
  read from the pane's visible terminal text (codex; claude pending its exact
  wording).
- **Live git state per room** in the Details tab — branch (or short SHA), ahead/
  behind vs upstream, ±diff vs HEAD, and a changed-files list. Read-only `git`
  with `--no-optional-locks`; shows for any conversation (agent or shell).
- **Usage-limit meters (5h / Weekly)** in the Details tab from the OAuth usage
  endpoint, with reset countdowns.

### Fixed
- **Pane clicks landed on the wrong pane** ("click top-right, focus bottom-right").
  The surface's window-level mouse-down monitor hit-tested in the contentView's
  own (flipped SwiftUI hosting) coordinate space, inverting Y. Pass the window
  point straight to `hitTest`; focus now resolves on mouse-down via the surface's
  own pixel-accurate AppKit hit-test.
- **Resumed agents were never detected as live** — so the minimap / your-turn
  lights / alerts didn't fire for them. macOS `pgrep` can't see the daemonized
  `dtach` master, and the surface's foreground pid is the `login`/dtach-client
  wrapper (uninspectable). Resolve the master via `lsof` on the socket → the real
  agent process.
- **Codex usage/turn detection read a dead file.** Codex `resume` forks a new
  rollout; the Details gauge/tokens/limits and done/working state now follow the
  file codex is actually writing (found via `lsof`), not the frozen registry one.
- **Usage-limit section no longer flickers out** on a transient empty read
  (carries forward the last-known windows).
- **Multi-line paste into agent TUIs** — bundle the `xterm-ghostty` terminfo and
  set `GHOSTTY_RESOURCES_DIR`, restoring bracketed paste (was falling back to
  `TERM=xterm-256color`).

### Changed — UI
- **Right inspector is now Details | Sessions.** Details = context gauge / tokens
  / 5h+Weekly limits / ports footer / git + pin glyph; Sessions = the quick-look
  minimap + parked-agent reattach strip. (Replaces the single Context surface.)
- Removed the spawned sub-agent ("Clawd pets") tiles.

### Performance
- Instant pane focus — resolves on mouse-down (no drag-arbitration deferral).
- Ambient polls (ports, context/usage, live-session reconcile, sub-agent scan)
  pause while the app is backgrounded and catch up on return.

## "Complete Overhaul" (2026-05-30, shipped in 0.2.0)

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
