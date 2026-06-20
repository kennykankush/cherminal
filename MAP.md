# MAP.md — Cherminal Atlas

> First devour: **2026-06-19**. Scope studied: full first-party tree (~12k LOC, ~60 Swift files
> under `Cherminal/`), build/CI config, test surface, and live runtime data sources. Vendored
> Ghostty (`Cherminal/Vendor/`, 75 files) treated as read-on-demand. **Treat every claim here as
> something to verify, not gospel** — file refs are given so spot-checking is cheap.

---

## Repo Identity

**Cherminal** = *chat + terminal*. A native SwiftUI macOS app that is "the room you enter to see
every AI agent conversation across your `~/dev/*` rooms, and jump back into any one." It is a
**3-pane shell** (conversations sidebar | live Ghostty terminal | context-watch cockpit) wrapped
around an embedded `libghostty`. See `VISION.md` for the full intent.

- **Language/build:** Swift 5 (`SWIFT_STRICT_CONCURRENCY: targeted`), SwiftUI + AppKit, **arm64-only**
  (libghostty is arm64-only — `project.yml:23`), deployment target **macOS 26.0**. Project generated
  by **XcodeGen** from `project.yml` (no committed `.xcodeproj` edits — regenerate with `xcodegen generate`).
- **Terminal engine:** `libghostty` vendored as `vendor/GhosttyKit.xcframework` (NOT committed — 134 MB;
  shipped as a GitHub **release asset** pinned by `vendor/GhosttyKit.version` = `vendor-libghostty-20260610`,
  cached in CI). Local dev builds it via `scripts/build-libghostty.sh`.
- **Persistence helper:** `dtach` (GPL-2.0) vendored at `vendor/dtach`, bundled into
  `Contents/MacOS/dtach` by a post-build script (`project.yml:53`), invoked as a separate executable.
- **Two side-by-side apps:** Release = `dev.hamulia.Cherminal` ("Cherminal"); Debug = `dev.hamulia.Cherminal.dev`
  ("Cherminal Dev", product `CherminalDev`) — separate bundle id / data dir / dtach socket dir so the dev
  build never disturbs the daily driver. Swift module name stays `Cherminal` in both (`@testable import`).
- **Installed daily driver:** `/Applications/Cherminal.app` v0.2.0 (build 5). Hadi runs Claude Code
  *inside* Cherminal, so `scripts/install.sh` does a session-safe in-place swap (survives via dtach);
  `⌘Q`+reopen applies.
- **Repo dir is `/dev/belvedere`** (legacy name); product/bundle renamed Cherminal 2026-05-29. Prefix
  for internal names is `CHM`.

**The one load-bearing rule** (`VISION.md:61`): **Observe externally. Never inject.** No hooks, no
wrapper binary, no env injection into agents. Cherminal reads agents' on-disk session files and
inspects OS processes (lsof/ps/git) out-of-band. *Verified live:* 55 dirs in `~/.claude/projects/`,
`~/.codex/sessions/` present, ~10 live dtach masters in `~/.cherminal/dtach/dev.hamulia.Cherminal/`.

---

## Terrain Map

Source root `Cherminal/`. Five subsystems + a vendored engine:

| Area | Dir | Role | Heaviest files |
|------|-----|------|----------------|
| **App shell** | `Cherminal/` (root) | Entry, lifecycle, DI, design tokens, diagnostics | `CherminalApp.swift:446`, `DesignTokens.swift`, `Diagnostics.swift` |
| **Discovery** (observe engine) | `Cherminal/Discovery/` (19 files) | Turn agent session files + OS state → a `Conversation` registry + usage math | `SessionCache.swift:463`, `ConversationUsage.swift:399`, `ConversationRegistry.swift:314` |
| **Terminal / NativeTabs / Grid** | `Cherminal/Terminal/**` (22 files) | The middle pane: native NSWindow tabs, pane grid, Ghostty surfaces, dtach persistence, process resolution | `NativeTabs/TabWindowCoordinator.swift:1841` ⚠️ |
| **UI panes** | `Cherminal/Sidebar/`, `Cherminal/Context/` | Left conversation rail + right "Cockpit" context watch | `Context/ContextWatchPane.swift:1081`, `Sidebar/SidebarView.swift:1030`, `Context/InspectorPane.swift:498` |
| **Models (the "laws")** | `Cherminal/Models/` (8 files) | Pure, unit-tested logic extracted from the coordinator | `ConversationLedger.swift:302`, `Conversation.swift`, `AttentionLaw.swift` |
| **Vendored engine** | `Cherminal/Vendor/Ghostty*` (75 files) | Minimal libghostty hosting layer (cmux-style, not the full Ghostty.app) | — read on demand |

**DI container:** `AppEnvironment.shared` (`Terminal/NativeTabs/AppEnvironment.swift`) — a `@MainActor`
singleton built once after `ghostty_init`, owning the single source of truth for every window:
`registry`, `ghostty` (`Ghostty.App`), `bookmarks`, `pins`, `labels`, `coordinator`, `ports`,
`caffeine`, `backgroundAgents`, `metrics`. **One** kernel `FilesystemWatcher` over both session roots
is fanned out to consumers at different cadences (registry 2.5s, coordinator ~0.3s) — `AppEnvironment.swift:24`.

**The two `@MainActor` ObservableObjects everything binds to:**
- **`ConversationRegistry`** — source of truth for *what conversations exist*. `@Published conversations,
  rooms, supersededIDs`. Built from cache snapshot → full scan → incremental FSEvents updates.
- **`TabWindowCoordinator`** — source of truth for *live state* and the owner of tab/pane lifecycle.
  `@Published liveConversationIDs, awaitingTurnIDs, awaitingPaneIDs, burstingAgents, tabOverviews,
  detachedAgents, tabCount, frontmostTabID`. **This is the heart and the hottest file (53 commits/60d).**

**`Conversation` model** (`Models/Conversation.swift:86`) — `id, agent (AgentKind), roomPath,
sessionFile, firstMessageAt, lastActivityAt, previewText, continuedFromID?`. Deliberately has **no
`state` or `messageCount`** (`Conversation.swift:94`) — "a model field nobody believes is bank-logic
rot." Liveness comes from the coordinator; pins from `PinsManager`; counts from the live accumulator.
`AgentKind` = `claudeCode | codex | shell | unknown` (shell is a synthetic conversation so bare
terminals flow through the same pipeline).

---

## Runtime Routes

### Boot (`CherminalApp.swift`)
`@main CherminalApp` has **no `WindowGroup`** — windows are AppKit-managed (only Scene is `Settings{}`
for menus). Lifecycle is in `CherminalAppDelegate`:
1. `applicationWillFinishLaunching:72` — `Diagnostics.bootstrap()`; register `persistentSessions=true`;
   set `GHOSTTY_RESOURCES_DIR` → bundled terminfo (without it, `TERM` falls back to xterm-256color and
   bracketed paste / kitty-keyboard break — the real cause of the old "can't paste into agent panes"
   bug); `ghostty_init()` (segfaults if any ghostty API runs first); `BinaryResolver.prewarm()`.
2. `applicationDidFinishLaunching:110` — start metrics/backgroundAgents, install tab-shortcut local
   monitor + Groups menu; honor "Don't Reopen"; **`sweepDtachSockets()`** (reap orphan masters) →
   restore shell-only tabs instantly, then in a `Task` load cache snapshot → `restoreSession()` →
   `restoreDetachedAgents()` → `enterPhase(.running)` → `registry.bootstrap()`.
3. **App-phase state machine** (`AppPhase`: launching → running ⇄ quitDeciding → terminating) gates
   persistence and parking so partial-restore never clobbers a good snapshot and quit-time parking
   doesn't race the reopen prompt. Quit persistence happens in `applicationShouldTerminate:187` (NOT
   `willTerminate` — by then all windows are closed and the snapshot would be empty).

### Open / focus a conversation (the core promise)
`SidebarView` row click → `coordinator.openOrFocus(:337)`: **dedup via `ConversationLedger.openPane(for:)`**
(exact `base.id` beats adopted `effective.id` — this is what makes "click X land on X"). If new, create
`TerminalTabWindowController` with a `Workspace(panes:[Pane(base)])`, join the native tab group, layout
synchronously, then `spawnSurface:389` on the next runloop (after the pane has real size). Spawn builds
config off-main (`TerminalCommand.surfaceConfig`, can block ~3s in BinaryResolver), then on-main creates
`Ghostty.SurfaceView` and moves focus.

### Keyboard (all via local NSEvent monitor — SwiftUI `.commands` don't route to AppKit tab windows)
`CherminalApp.swift:382` `handleTabShortcut`: ⌘T new shell, ⌘D split pane, ⌘` cycle panes, ⌘1–9 select
tab, ⌘⇧]/[ next/prev tab, ⌘⇧W close pane (parks agents), ⌘⌥⇧W **kill** pane (no park), ⌘⇧↩ zoom,
⌘⇧J jump to next waiting agent, ⌘⇧R rename tab.

### Focus model (was buggy, now law)
Live panes focus through `SurfaceView.mouseDown` (AppKit pixel hit-test; the OS routes to the pane under
the cursor). `SurfaceView.becomeFirstResponder` posts `chmSurfaceDidBecomeFirstResponder` →
`coordinator.syncActivePane:607` → updates `workspace.activePaneID`. Surface-less cells (spawning/
suspended) fall back to a SwiftUI `DragGesture`, **disabled on live panes** (`TerminalGridView.swift:138`)
so it can't swallow clicks. Programmatic focus always routes through `focusPane:583`. Prior bug: a
TapGesture-on-mouseUp + a flipped-coordinate hit-test caused "click one pane, type into another" —
fixed by the mouseDown + first-responder-notification scheme.

### Discovery scan pipeline (file → registry → UI)
`~/.claude/projects/<encoded-cwd>/<id>.jsonl` + `~/.codex/sessions/.../rollout-*.jsonl` → `FilesystemWatcher`
(FSEvents, per-subscriber debounce) → `SessionScanEngine.stream` (stat-sweep → **cache hit emits instantly**
→ parse misses concurrently, limit 8) → `ClaudeSessionScanner` / `CodexSessionScanner` (head+tail parse via
`SessionParser`; `PathEncoder` decodes the slugged dir) → `SessionCache` (SQLite, keyed `(path, mtime, size)`;
also stores pins/bookmarks) → `ConversationRegistry` (publishes; `RegistryMerge.newestByID` resolves the
codex-fork-on-resume case where two files share one id) → `SidebarView`. Compaction chains: Claude writes the
parent path + a "Continue the conversation…" handoff into the child's first turn → `continuedFromID` →
sidebar dims the superseded parent.

### Usage / rate-limit math (the Cockpit)
`ContextWatchPane` polls every 8s **only while its tab is visible** (`controlActiveState` guard).
- **Context %:** mirrors each agent's own formula. Claude: budget = `window − 20k output reserve − 13k
  compact buffer`; window bumps to 1M if model id contains `[1m]`/`opus-4-7/8`/`sonnet-4-6`. Codex:
  12k baseline subtracted from both used and window. (`Discovery/ConversationUsage.swift`,
  `ContextBudgetLaw`.) Claude uses a resumable **accumulator** (folds deltas, 16k tail/poll); Codex
  tail-parses every poll because `resume` forks a new rollout file.
- **Account windows:** `UsageWatch.shared` + `ClaudeRateLimits` (Anthropic OAuth endpoint, Keychain→file
  cache, 60s throttle, 15min stale cutoff) for Claude; in-file `rate_limits` for Codex. Pure laws in
  `Discovery/UsageLaw.swift`: `RateWindowLaw.freshen` (zero windows past reset — auto-clears stale burst
  banners), `PaceLaw.pace` (deficit/reserve "is burn ahead of even drain"), `BurstLaw.isLimited`
  (in-file flag → ≥99.5% meter → banner+≥95% fallback), `UsageAlertLaw` (90% up / 50% down transitions,
  fire notifications via `FleetAlerts`).

### Attention / "your turn" light
8s reconcile + FSEvents → `TurnState.read` (Claude: last assistant `stop_reason == end_turn/stop_sequence`;
Codex: last record is `task_complete`) → `AttentionLaw.verdict` (pure: lit iff awaiting AND file grew past
seen AND not currently viewing; clears on focus) → `awaitingTurnIDs` (gated, for sidebar + notifications)
and `awaitingPaneIDs` (raw, for the Sessions-tab minimap). `FleetAlerts` posts a banner + Dock badge when
an agent finishes in a pane you're not watching; tapping it jumps there.

### CLI/script paths
`scripts/`: `install.sh` (session-safe in-place app swap), `build-libghostty.sh` + `fetch-ghostty.sh`
(vendor the xcframework), `release.sh`, `e2e-dtach.sh` (the dtach survival E2E). Casks/ + dist/ are
distribution scaffolding (deferred — needs Developer ID, team 29CYQWJSMF).

---

## Temporal Map

- **Before anything:** `ghostty_init` must precede the first `AppEnvironment.shared` touch (process-wide
  C globals; segfault otherwise). `GHOSTTY_RESOURCES_DIR` must be set before `ghostty_init`.
- **dtach masters outlive the app.** Each pane's shell runs under `dtach -A <socket> -z -r winch /bin/sh
  -c <cmd>`; the master `setsid`s and reparents to launchd, surviving surface teardown and ⌘Q. Socket =
  `~/.cherminal/dtach/<bundle-id>/<base.id>.sock`. `-A` both creates-fresh and reattaches-survivor, so the
  same spawn path handles new + restore. Agents are *always* wrapped; shells wrapped if `persistentSessions`
  on OR a live master already exists.
- **Platform gotchas (load-bearing):** macOS `pgrep` is **blind** to a daemonized dtach master — detect via
  **`lsof` on the socket file** (`Dtach.swift`). Agents also run under a setuid-root `login` wrapper `lsof`
  can't read — resolve through the socket / tpgid, not the surface pid. `ProcTable.capture` takes **one**
  `lsof` + **one** `ps` snapshot per poll (TTL ~3s), not per-pane. `ps etime` → absolute start time feeds
  the freshness guard.
- **Restore order at launch:** clear-if-dont-reopen → `sweepDtachSockets` (keep-set = every persisted
  pane id + foreign socketID + tray id, via `ConversationLedger.sweepKeepSet`) → `restoreSession`
  (`openPersistedWorkspaces`, one ProcTable snapshot answers all liveness, `restorePlan` decides
  attach-live vs cold-resume, `preAdoptIfLiveAttach` flips identity optimistically) → `restoreDetachedAgents`
  (tray) → `reconcileLiveSessions` 4s later re-verifies adoption against real process state.
- **Async/cadence:** registry FSEvents debounce 2.5s; coordinator ~0.3s; usage poll 8s (visible tab only);
  git poll 6s; backgroundAgents `claude agents --json` 15s; persistence debounced 1s; ClaudeRateLimits 60s.
- **Anti-leak reaping:** parked shells capped at 16, reaped >24h (`ConversationLedger.shellTrayReaps`);
  parked **agents never auto-reaped** (user kills via tray). `CaffeineManager` now holds keep-awake as
  **in-process IOKit assertions** (released the instant the process dies) — not a `caffeinate` child,
  which orphaned to launchd and leaked.
- **Churn (last 60d, fragility signal):** `TabWindowCoordinator.swift` **53**, `CherminalApp.swift` 27,
  `SidebarView.swift` 26, `ContextWatchPane.swift` 22, `InspectorPane.swift` 14, `ConversationRegistry` 12.

---

## Blast Radius Map — *if you touch X, inspect Y*

- **`Conversation` model fields / `id` type** → `SidebarView` rows, `ContextWatchPane`, registry lookups,
  coordinator tracking, pane adoption, `@AppStorage` pin/label keys, `SessionCache` schema. `id` is a
  `String` used as both registry key *and* dtach socket name — changing it is wide.
- **`TabWindowCoordinator`** (highest blast radius) → consumed by `TerminalTabWindowController`,
  `TerminalGridView`, `InspectorPane`, `TabWindowRootView`, `PlaceholderRootView`, `SidebarView`. The
  ledger invariants below are the contract.
- **Pane identity** (`Pane.id`) → `TerminalGridView` keys cells by `pane.id`, not grid slot
  (`TerminalGridView.swift:7`); re-keying by position re-parents surfaces to wrong cells (the ">4 panes
  grid corruption" bug). Keep `ForEach(workspace.panes)` pane-stable.
- **dtach socket naming / `PersistedPane.socketID` semantics** → restore can't reattach live masters;
  every agent cold-resumes (loses live state) or duplicate masters spawn. The shell-adopts-agent case
  persists the *shell* socket (`ConversationLedger.socketToPersist`) — subtle, test-covered.
- **`ConversationLedger` rules** (`Models/ConversationLedger.swift`) → THE law module: `openPane`,
  `claimIdentities` (no two panes serialize one id), `restorePlan`, `dedupeForRestore`, `canPark`,
  `detectConversation` (the freshness guard prevents a new chat inheriting the room's previous
  conversation — the "BELVEDERE FABLE on a brand new chat" bug), `shellTrayReaps`, `sweepKeepSet`.
  Change here ripples into restore, persistence, parking, hand-launch adoption all at once — but it's
  pure and the most unit-tested code in the repo.
- **Session-file format assumptions** (Claude JSONL stop_reason, Codex `token_count`/`task_complete`,
  the compaction handoff phrase, dir depth) → `SessionParser`, `*SessionScanner`, `TurnState`,
  `ConversationUsage`, `SessionPulse`. External format drift breaks these silently.
- **`AppPhase`** → persistence + parking guards in coordinator + `applicationShouldTerminate`. Remove it
  and quit/restore races return (double-park, clobbered snapshot).
- **`CHM.Phase` wall-clock motion** (`DesignTokens.swift`) → all ambient lights (sidebar breathing dot,
  minimap done-glow/working-sweep). House rule: **never `repeatForever` ambient animation** (restarts on
  re-render) and **one persistent `List`** in the sidebar (never per-mode Lists — NSTableView re-entrance).

---

## Change Playbook

- **Regenerate project after adding/moving files:** `xcodegen generate` (sources are folder refs in
  `project.yml`; new files are picked up automatically, but the `.xcodeproj` must be regenerated).
- **Build + test locally:** `xcodebuild -project Cherminal.xcodeproj -scheme Cherminal -configuration
  Debug -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test`. Needs
  `vendor/GhosttyKit.xcframework` present (build via `scripts/build-libghostty.sh` or fetch the pinned
  release asset). **140 `@Test` cases (Swift Testing, not XCTest) across 17 files** in `CherminalTests/`.
- **CI:** `.github/workflows/ci.yml` on `macos-26`, every push to `main` + every PR. Caches the
  xcframework by `vendor/GhosttyKit.version` tag; picks newest Xcode; `xcodegen generate`; build+test.
- **Deploy to daily driver:** `scripts/install.sh` (in-place swap, survives running inside Cherminal),
  then ⌘Q + reopen.
- **Safe extension points:** add a new pure law to `Models/` + a `@Test` (the established house pattern);
  add a Discovery scanner/parser behind `SessionScanEngine`; add UI in a new drawer in `ContextWatchPane`
  or a sidebar mode (respect the one-List + wall-clock-motion rules). Settings live in code or one JSON,
  not a settings UI (`VISION.md` non-goals).
- **Before editing the coordinator:** read `ConversationLedger.swift` first — most "rules" you'd be
  tempted to inline already live there as tested pure functions; delegate, don't re-derive.
- **The Wall (`VISION.md:91`):** no embedded browser, no approval queue/Feed, no hooks/RPC, no IDE
  features (file tree, problems panel), no general-purpose abstractions. If a feature isn't about
  *conversations*, it doesn't ship. If it requires injecting into an agent, it doesn't ship.

---

## Unknowns And Next Probes

1. **`.suspended` pane lifecycle** — `Pane.lifecycleState` has a `.suspended` case and UI copy
   ("Suspended — click to resume") but no studied code transitions into it. Is suspend/resume wired, or a
   stub? *Probe:* grep for `.suspended` writes across `Terminal/`.
2. **`PaneRole` / role tagging** — defined in `GridGeometry`/`Pane` but never written. Reserved feature?
3. **Zoom → unzoom PTY reflow** — comment says hidden siblings keep grid frames so PTYs don't reflow;
   unverified what happens to sibling PTYs on un-zoom of a multi-pane grid. *Probe:* runtime test.
4. **Reattach-from-tray age reset** — `restoreDetachedAgents` preserves original `detachedAt`
   (`ConversationLedger`/coordinator ~1338) but the live `reattach` path may reset it; possible
   inconsistency in shell-age reaping. *Probe:* read `reattach` vs restore park-time handling.
5. **Codex live-rollout tracking** — `resume` forks a new rollout file; coordinator caches `liveFile(for:)`
   per id each reconcile. If wrong, the usage gauge goes stale. *Probe:* observe a codex resume live.
6. **`LiveSessionLinker.inspect` resolution under load** — adoption is optimistic + reconciled at 4s;
   is there a window where a sidebar click spawns a duplicate cold-resume before reconcile? *Probe:* race test.
7. **ClaudeRateLimits silent-expiry** — token revoked without a 401 keeps stale windows until the 15min
   cutoff; no foreground refresh trigger. *Probe:* confirm refresh-on-activate behavior.
8. **Vendored Ghostty surface** (`Cherminal/Vendor/`, 75 files) — only the hosting seams
   (`GhosttyBridge`, `SurfaceView`, `Ghostty.App`, `moveFocus`) were touched here; the internals are
   unmapped. The `as? AppDelegate` cast deliberately returns nil so controller-coupled vendored features
   stay off (`CherminalApp.swift:63`) — verify before relying on any vendored feature.

---

## Readiness

**Ready to make, with grounded judgment:** changes to the pure law modules (`Models/`, `Discovery/*Law`)
with tests; Discovery scanners/parsers; usage/context math; sidebar + cockpit UI (within the house
rules); attention/notification logic; persistence/restore tweaks (via the ledger).

**Requires deeper study first:** the `TabWindowCoordinator` pane/tab/dtach lifecycle in its full detail
(1841 lines, 53 commits — highest fragility; understand the AppPhase + ledger interplay before mutating);
anything reaching into vendored Ghostty internals; the `.suspended` lifecycle and zoom PTY behavior
(unknowns #1, #3). Live runtime probes (not just code reading) are the right next step for unknowns #3–6.
