# Session log — the tmux/sheol arc (2026-07)

A detailed record of one long working session, written so a future Claude/Codex
session (or a human) can pick up with the full story — not just the diffs, but
the *decisions, reversals, and bugs*, which are where the real knowledge is. For
the design intent going forward see [`HANDOFF-NOTES.md`](HANDOFF-NOTES.md); for
how the repo works see [`CLAUDE.md`](CLAUDE.md) and [`README.md`](README.md).

## What got built (roughly in order)

1. **Browser gestures** — `s a` generalized from Safari-only to cycling the
   *frontmost* browser's windows (Safari/Chrome/Arc/Brave/Firefox) via the OS's
   native ⌘\` (native per-browser AppleScript reorder only works in Safari, so we
   ride the OS shortcut). `l l` = ⌘L to the frontmost app (universal address bar).
   New `reload-leaderkey.sh` (Leader Key doesn't hot-reload).
2. **`VISION.md`** — the shareable project vision (hybrid tiling WM + input layer;
   necromancer terminal direction).
3. **`MANUAL-WIRING.md`** — the click-through onboarding surface the app must
   later automate; corrected a wrong ⌘W bind syntax (`\(id)` → `id`) repo-wide.
4. **Busy-pane shield redesign** — 4-beat (damage/damage/break/skull-death),
   terminal-native visuals, Halo regen, procedural SFX. Then the sound got
   rejected (3 passes), then the whole feature got removed, then **restored as
   opt-in, off by default** (see reversals).
5. **tmux protection + sheol** — the centerpiece:
   - `t t` launch a tmux-protected pane (plain tmux, one window).
   - `t d` split the current pane into a protected one.
   - `t m u x` → **sheol**, the necromancer's ledger of tmux "spirits": LIVING
     (attached) vs SHEOL (detached) rosters, auto-refresh, `r` revive (new
     window), `c` commune (peek in place, status bar shows the way back),
     `d·d·d` banish (living → detached to sheol; dead → exiled/killed).
6. **Splash** — dragon logo dropped to ~1-in-10.
7. **`i t`** — brings all iTerm windows forward (was a plain app-launch).
8. **Philosophy** — "reduce window overflow" added as a stated design goal
   (README + CLAUDE.md).

## Key decisions & reversals (the interesting part)

- **`tmux -CC` → plain tmux.** Control mode was the initial spec, but in practice
  it spawns tmux windows as separate native iTerm windows AND leaves a confusing
  "gateway" window — two windows per launch. Switched to plain tmux: one window,
  status bar as the "protected" proof. Lesson: the fancy integration wasn't worth
  the confusion.
- **Shield: built → removed → restored as opt-in.** The shield worked
  mechanically but its *point* was aesthetic game-feel, which never fully landed
  (see sound saga). We removed it (its safety is a one-checkbox iTerm setting:
  Profiles → Session → "Prompt before closing if jobs running"). Then the owner
  missed it, so it came back as an **opt-in, off-by-default** toy: wire ⌘W once,
  toggle instantly via a flag file (`shield-on.sh`/`shield-off.sh`) — no
  re-wiring. Lesson: know which medium carries which idea; keep the toy behind a
  flag instead of deleting or defaulting-on.
- **Sound bounced 3×.** Procedural stdlib synthesis (sine/noise/biquad) cannot
  hit "cool minor-key cybergoth" — it reads corny no matter how it's shaped. The
  shield ships silent; SFX is a drop-in contract (filenames the daemon no-ops on
  if absent). Lesson: stdlib DSP is fine for UI blips, wrong for musical vibe;
  that needs real samples or a real synth.
- **`d·d·d` banish went two-tier** on request: living spirits get *detached* into
  sheol (recoverable); already-dead ones get *killed* (exiled). Thematically
  clean and it reuses the shield's ward motif.

## Bugs found & fixed (war stories — read these before touching the TUI)

These were mostly caught by the owner testing in the **real** iTerm environment,
not by headless tests. That's the theme: interactive-terminal behavior is where
headless testing lies to you.

- **bash 3.2 rejects fractional `read -t`.** macOS ships bash 3.2. `read -t 0.05`
  throws "invalid timeout specification" and silently fails → arrow-key nav in
  sheol did nothing (j/k worked, arrows didn't). Fix: integer timeouts only.
- **bash 3.2 returns `1` for BOTH read timeout AND EOF.** My "EOF guard" assumed
  a timeout returns >128 (true in bash ≥4, NOT in 3.2). So every refresh tick
  tripped the guard and sheol *exited ~2s after opening*. Fix: distinguish by the
  tty (`[ -t 0 ]`) — live terminal = timeout (refresh); closed stdin = real EOF
  (exit). Version-independent.
- **A cleanup trap that doesn't `exit` swallows SIGTERM.** `trap cleanup EXIT INT
  TERM` (without exiting) meant `pkill` couldn't kill sheol → the single-instance
  opener failed → **instances piled up, each redrawing every 2s → WindowServer
  pegged, keyboard lag, hot Mac.** Fix: `trap 'cleanup; exit 0' INT TERM`, plus a
  `-9` fallback in the opener, plus...
- **Redraw churn.** The TUI redrew a full alt-screen frame every 2s
  unconditionally. Fix: redraw ONLY when a change-signature differs. But the first
  signature was too *narrow* (names/count only), so a **task changing or a session
  detaching didn't trigger a redraw** until the user moved. Fix: signature now
  includes command + living/dead state + minute-bucketed times. Poll dropped to
  ~1s; still cheap because redraw only fires on real change.
- **I killed the owner's real tmux sessions with `tmux kill-server` during
  testing.** kill-server nukes the whole default-socket server. Fix (process, not
  code): all tmux testing now runs on an isolated `TMUX_TMPDIR` socket. Flagged
  here because it's an easy, destructive mistake to repeat.

## Technical lessons (portable takeaways)

- **Assume bash 3.2 for any shell TUI here.** No fractional `read -t`; timeout and
  EOF are indistinguishable by return code (use the tty); watch empty-array
  expansion under `set -u`.
- **Terminals aren't game engines.** Per-pane visuals are limited to bg-color +
  badge + injected text; there's no compositor, no audio engine. Game-feel lives
  better in a TUI's *language and pacing* (sheol) than in trying to render
  particles per pane (the shield).
- **Any long-running TUI must:** trap-and-exit on signals, redraw only on change,
  guard the read loop against EOF, and enforce single-instance — or it piles up
  and cooks the machine. All four bit us here.
- **Test interactive TTY behavior under a real pty** (Python `pty.fork`), and
  make the assertion unambiguous (a "1 draw" count meant both "no redraw needed"
  AND "process died" at different times — a false-positive trap).
- **Isolate tmux tests on `TMUX_TMPDIR`.** Never `kill-server` a shared socket.

## The reptyr question — can we reparent a *running* process into tmux on macOS?

Short answer: **no, and it's not worth pursuing.** The hard constraint that shapes
sheol ("necromancy only revives the tmux-born") comes from tmux needing to be the
parent from launch. On Linux, [`reptyr`](https://github.com/nelhage/reptyr) works
around exactly this — it uses `ptrace(2)` to attach to a running process, read and
rewrite its file-descriptor table, and steal/replace its controlling terminal, so
you can pull an orphaned process into a new pty (and thus tmux). Porting that to
macOS runs into a wall:

- **`ptrace` on macOS is a stub.** No `PTRACE_PEEKDATA/POKEDATA`-style arbitrary
  memory access; the real lever is `task_for_pid()`, which requires **root + the
  `com.apple.security.cs.debugger` entitlement**, and is blocked against most
  processes by **SIP** and the hardened runtime.
- **Reparenting a controlling TTY** (`TIOCSCTTY`, rewriting another process's fd
  table) needs the invasive cross-process memory access macOS specifically
  prevents. Even Linux reptyr is fragile (epoll, some fd setups, etc.).
- **Net:** a Mac "reptyr" would require disabling system security, run as root,
  carry special entitlements, and *still* be fragile and per-macOS-version
  brittle. It fights the OS at the exact layer Apple has hardened most.

**Recommendation: don't build it.** The launch-time model (`t t` / `t d`) is
simpler, robust, and honest, and the theme absorbs the limit gracefully. If
"protect what's already running" ever becomes important, the *right* shapes are:
(a) nudge users to start long work in tmux from the jump (make `t t` frictionless,
maybe auto-suggest it), or (b) a machine-spirit "fragile terminals" ledger that
*lists* unprotected panes (via iTerm's API) and offers a one-key "relaunch this in
tmux" — recreating, not reparenting. Reparenting is the wrong hill.

## Open threads carried forward

- sheol **nag** (Dock/menu-bar haunt while spirits wander) + a **GUI ledger** tab
  → the machine-spirit app (needs a GUI agent).
- **Non-tmux "fragile" panes** in the ledger → needs iTerm API pane enumeration.
- **`i t`** can't pull windows from other Spaces (macOS/Mission Control limit).
- **`c` commune** leaves a `status-right` hint on the session after detach — could
  scope/reset it.
- Truly **instant** sheol updates (0-latency vs ~1s poll) → tmux `set-hook`
  driven; deferred as unnecessary complexity for now.
- **Page-field cycling** (`l l` extended) → browser extension, Phase 3+ (#20).

## Codex second-opinion prompt

See the end of the chat / paste this to Codex:
> Review the machine-spirit repo's recent tmux/sheol + shield work for
> correctness, macOS-bash-3.2 portability, security (public repo, zero secrets),
> and cleanup. Focus files: `bin/tmux-sheol.sh`, `bin/tmux-sheol-open.sh`,
> `bin/tmux-session.sh`, `bin/tmux-launch.sh`, `bin/tmux-split.sh`,
> `bin/iterm-new-window.sh`, `bin/iterm-front.applescript`, `bin/pane-shield.py`.
> Specifically check: the sheol read-loop (bash 3.2 timeout/EOF handling, the tty
> guard, single-instance kill logic, the change-signature redraw), any
> unquoted-expansion / empty-array / `set -u` hazards, AppleScript injection via
> the `command "$cmd"` string in `iterm-new-window.sh`, and whether any shell
> script can leak or mis-handle a session name with spaces/quotes. Suggest
> minimal, surgical fixes; do not restructure working features.

---

# Session log — the Phase-1 app build (2026-07-06)

One very long day: the machine-spirit APP went from nothing to a running
SwiftUI tool. Written for the next session (or Claude chat) to pick up.

## What stands (all committed, [P1.1]–[P1.20], pushed)

- **Ratchet infra:** CHECKPOINTS.md ledger; `v0.1-stable-config` tag = the
  pre-app loved state, restorable in one command.
- **Forks vendored + building:** LeaderKey + Rectangle as squashed subtrees
  under `forks/` (MIT recorded in FORK-NOTES.md with working ad-hoc build
  commands). Fork patches: Mini indicator wears the sigil; letter-accretion
  wordmark as keys land. NOT the daily driver yet — cask app still runs.
- **MachineSpiritKit** (`kit/`, 26 headless tests): lossless Leader Key
  importer (unknown fields survive in `extras`), serializer with canonical
  round-trip gate (fixture AND live config), group+action duality native,
  derived inertness via injectable probes, radial + tidy-tree layouts,
  GraphViewState sidecar type.
- **MachineSpirit.app** (`app/`, XcodeGen): directory + node-graph panes
  side by side + embedded sheol terminal pane (SwiftTerm 1.5.0, owner's
  hacker.itermcolors, real PATH); letter-walk both views (LK grammar), Esc
  home, ⌫ up, ⌘R refresh w/ regrow animation, Tab cycles all three panes;
  radial board with interlocked leaf stacks, straight obstacle-bowed
  traces, identity colors + app icons + favicons, chain-word boxes
  (q»uit), key chips above icons; drag nodes (roots move trees, ⌘-click
  multi, rubber band), positions + viewport persist in sidecar; nothing
  hides at any zoom; growth animation on boot/refresh; typewriter header;
  directory cascade; sheol footer nag; sigil app icon.
- **sheol-core** (`bin/`): shared verb layer (list/--json/revive/detach/
  kill), TUI rewired through it, parity proven on isolated sockets. TUI
  gained `n` = new living spirit (repo copy only — live ~/bin untouched by
  Phase-1 law; goes live at next install/sync).

## Owner rulings that now govern (design cache #26–#36)

#26 live process state NEVER in the config graph (commands yes, healthbars
no — sheol lives in its own pane/terminal). #29 every aesthetic is a future
user parameter. #35 the owner's hand-dragged layout (persisted in the
sidecar) is the ground truth for a future learned auto-organizer. #36 bind
executions should pulse the graph — needs the LK fork to ping the app (a
big reason the fork exists).

## Honest misses / rough edges this session

- Aesthetic iteration churned: curves and sway went through build→veto→
  rebuild→simplify cycles (final state: straight lines, bow only where a
  node must be cleared; sway removed). Lesson: get a visual sign-off on a
  SKETCH before building motion systems.
- Directory HSplitView width fights window restoration (drag once).
- Label overlap at extreme zoom-out remains (label-aware routing = #31;
  learned layout = #35).
- v0.3-phase1 tag NOT yet laid — owner verification pending.

## Where we are in the roadmap / what's next

Phase 1 (read-only witness + altar + sheol plumbing) is functionally done
pending the tag. NEXT PHASE per owner: **stop configuring Leader Key +
Rectangle and start BEING the thing** — wire machine-spirit up as the
input layer:
1. The LK fork becomes the daily driver (supervised swap; the cask app
   retires) — fork pings the app on fires (#36), owns settings-open (#18).
2. Write-back: the kit's serializer starts WRITING the config (with backup
   + reload) — the +/− buttons come alive; the m-a-c-h-i-n-e-s-p-i-r-i-t
   summon bind lands then too.
3. Native window engine: Rectangle's actions reimplemented (or the fork
   driven directly) so `rectangle://` URLs stop being the interface.
4. Multiple leaders for real (MB4 exhibit → configurable input listeners).

## Codex second-opinion prompt (Phase-1 app build)

> Review the machine-spirit Phase-1 app work for correctness, performance,
> portability (public repo, zero secrets, no hardcoded usernames), and Swift
> hygiene. Focus: `kit/MachineSpiritKit/Sources/**` (is the round-trip truly
> lossless for adversarial configs — duplicate keys, non-string knowns,
> deep nesting? is `folderDisplayName` username-safe for edge paths?),
> `app/MachineSpirit/Sources/GraphView.swift` (per-frame allocation in the
> Canvas closure; the O(E×N) obstacle scan; gesture state machine — can
> dragMode wedge?; hitTest at low zoom), `AppState.swift` (the NSEvent key
> and scroll monitors: retention, event consumption correctness, the
> TerminalView passthrough-by-class-name check, walk semantics),
> `SheolService.swift` + `LedgerPane.swift` (Process spawning, SwiftTerm
> process lifetime on pane close — is pkill -f safe enough?, first-responder
> handling, the #filePath repo-path resolution's behavior in a
> non-dev-machine build), `IconStore.swift` (favicon fetch: network failure
> paths, cache growth, MainActor discipline), sidecar JSON read/write
> (corruption tolerance). Shell: `bin/sheol-core` (zsh; quoting, =exact
> target matching) and the `n` key addition in `bin/tmux-sheol.sh`
> (bash-3.2-clean? read-loop unaffected?). Suggest minimal, surgical fixes;
> do NOT restructure working features; the round-trip test gate
> (`cd kit/MachineSpiritKit && swift test`, 26 tests) must stay green.

## ⚠ War story (Phase 2, 2026-07-06 ~22:49): the fork's own tests ate the live config

Running the LeaderKey fork's full test plan (`-testPlan TestPlan`) **deleted
the owner's real `~/Library/Application Support/Leader Key/` directory and
left a 16-byte `{ invalid json }` corpse as config.json.** Root cause is
UPSTREAM's `testCreatesDefaultConfigDirIfNotExists`: it calls
`UserConfig.defaultDirectory()` — the REAL config home — and
`removeItem`s it to test the bootstrap path; sibling tests then write junk
configs through the same resolver. The suite's per-test UserDefaults/temp-dir
isolation does not cover that one static path.

- **Detection:** the kit's new `liveConfigCopySurvivesTheFullRitual` test
  (P2.6a) read the live config minutes later and failed on parse — the
  write-back gate's philosophy (prove the artifact before trusting it)
  found the corruption almost immediately.
- **Blast radius:** on-disk config only. The running cask Leader Key never
  hot-reloads, so the owner's keyboard kept working from memory the whole
  time.
- **Recovery:** repo mirror (`config/leader-key/config.json`, `__HOME__`
  expanded) validated and moved atomically into place — 151 nodes. The live
  config had drifted ~2 nodes ahead of the repo (Phase 1 never synced —
  read-only law), so the drifted binds exist ONLY in the cask app's memory:
  when the owner is next present, any config edit in LK's settings will pop
  its "changed on disk" conflict alert — choose **Overwrite** to land the
  in-memory truth, then `sync.sh`. If LK restarts before that, the floor is
  the 151-node repo state.
- **Fix:** fork patch — `defaultDirectory()` resolves to a temp sandbox
  whenever XCTest is loaded, so NO test (present or future-merged) can
  reach the real config home. Full test plan re-run: green, live config
  byte-identical before/after.
- **Law renewed:** the tmux law generalizes — **any test suite that can
  write the machine gets a sandboxed resolver before its first run.** The
  corrupted corpse is preserved in the session scratchpad.

## Session close addendum ([P1.21]–[P1.23], 2026-07-06 ~21:30)

- Keystroke chips ride whole and true: `[l-s-n-m]`, bracketed/dashed, above
  icon faces (the chain-walk that dropped branch prefixes is gone — chips
  read the structural id).
- The 7:09pm board restored as the resting design: [P1.15] radial layout +
  junction-ring cubic traces (minor curves), sway retired, obstacle bow
  kept. All later features layered on top untouched.
- Owner's hand layout (156 positions) persisted in the sidecar AND backed
  up to `graph-view.hand-layout-2026-07-06.json` — the ground truth for the
  learned auto-layout (#35).
- ⚠️ First task next session: make "sort" NON-destructive (named layouts,
  toggle radial ⇄ hand) — today it clears the hand layout (backup exists).
- `v0.3-phase1` tagged at session close: Phase 1 done — the witness, the
  altar, sheol's pane and core, both forks building, the loved state one
  command away.

---

# Session log — Phase 2, the wiring (2026-07-06 → 07-12)

The crossing: machine-spirit stopped *viewing* the config and started *being*
the input layer. Ended at **v0.4-sovereign-driver** — the fork drives the
keyboard under its own identity and the board pulses when a bind fires.

## What stands (all committed + pushed, [P2.1]–[P2.6], tags v0.4)

- **[P2.1] Codex hardening adopted** + two truths corrected: the "duplicate
  JSON keys fail loudly" claim was FALSE (JSONDecoder silently keeps the
  first) — built the guard, then documented it; sheol `sig()` joints ride
  \x1f. Kit gate 26→28.
- **[P2.2] Sort made non-destructive**: named layouts radial ⇄ hand, toggle
  in the zoom strip, migration of the owner's 156-position sidecar. **[P2.2b]**
  a guarded true-reset (wipes hand layout behind a confirm). Gate 28→29.
- **[P2.4] Fork hot-reloads** its config (DispatchSource, debounced,
  rename-survival unit-tested). **[P2.4x] THE INCIDENT** — running the fork's
  own test plan DELETED the live config (upstream test removes the real
  config home); caught by the kit's live-config-copy test, restored from repo
  mirror, fork patched to sandbox `defaultDirectory()` under XCTest. Two
  drifted binds later recovered from the cask's memory (Passwords, Xcode).
- **[P2.5a–e] The fired pulse (#36), end to end**: app registers
  `machinespirit://`, resolves `fired?path=s/s/w/s` to a route, pulses it
  (comet head + lit route + arrival burst; all #29 knobs). Fork fires the
  ping on every executed bind ([P2.5d]). **Witnessed live** — a real keystroke
  pulses the board. Snags cleared: a ghost-window bug (SwiftUI spawned a new
  window per URL → `handlesExternalEvents`), a paused-clock bug (calm board
  froze before the wave drew), and the whole thing was invisible until the
  route-glow + comet made it unmissable.
- **[P2.6a] Write-back machinery** (`ConfigWriter`): gate precondition →
  backup → temp-write + re-import validation → atomic swap → node-level
  report. Proven against temp targets + a copy of the live config. Gate
  29→36. **NOT yet wired to the UI** (that's 6b, next).
- **[P2.6] The fork's own identity**: bundle id `com.machinespirit.leader-key`,
  display name "MachineSpirit Leader Key". Installed permanent, drives the
  keyboard, fires pulses.
- **app-jump** (was browser-jump): one app-agnostic script — launch / focus
  (un-minimize) / cycle-windows-in-order — bound to `s a` (Safari), `c h r`
  (Chrome), `f i` (Finder). Any Cocoa app is one config line.

## Key decisions & reversals (the interesting part)

- **Duplicate bundle id was the root of every swap snag.** Both cask and fork
  were `com.brnbw.Leader-Key`, so `open <fork>` bounced to the cask, TCC
  grants were ambiguous, login items fought. First swap LOOKED like it worked
  (binds worked) but the cask was actually driving (no pulse). Fix: give the
  fork its OWN bundle id + display name. Launch by direct binary path when
  bundle ids still collide.
- **Live boundary deliberately opened** (Phase-2 charter): live writes allowed
  through the write-back machinery and supervised swaps only. The swap + the
  s-a/f-i rebinds were supervised live edits, sync'd back.
- **strings/nm are blind to Swift literals** — wasted a diagnostic loop
  "proving" the ping code wasn't compiled when it was. Only runtime proof
  counts.
- **Pulse per-keystroke** (owner idea, cached #37): pulse each key as typed,
  retract on backspace — a live typing mirror vs completed-route replay.
  Deferred.

## ⚠️ CURRENT LIVE-SYSTEM STATE (not in git — read before touching the driver)

- **Driver:** `~/Applications/MachineSpirit Leader Key.app`
  (`com.machinespirit.leader-key`), running, launches at login via
  `~/Library/LaunchAgents/com.machinespirit.leader-key.plist`.
- **Prefs domain** `com.machinespirit.leader-key` seeded from the cask
  (F19 activation = `KeyboardShortcuts_navigate` carbonKeyCode 80).
- **Cask** (`/Applications/Leader Key.app`, `com.brnbw.Leader-Key`): NOT
  running, OFF login startup, TCC reset. Kept installed for rollback only.
- **Rollback** (in FORK-NOTES): `launchctl bootout
  gui/$(id -u)/com.machinespirit.leader-key`; `pkill -f 'Applications/Leader
  Key.app'`; re-enable cask launch-at-login; re-grant its Accessibility.
- **⚠️ Ad-hoc signing caveat:** the fork's signature changes on every rebuild,
  so after any fork CODE change macOS re-prompts for Accessibility. Permanent
  fix (personal-team stable signing) noted in FORK-NOTES, unbuilt. Day-to-day
  use never triggers it.
- **The board** (MachineSpirit.app) must be running for pulses to show; it's
  read-only against the live config (write-back UI not wired yet).

## Where we are / what's next

Phase-2 priority spine (1→3→4→6a) is DONE. Remaining Phase-2 flesh:
- **Step 6b — "the pen"** (NEXT): wire `ConfigWriter` ([P2.6a], already built +
  tested) to the app's +/− buttons — add/remove a leaf bind through the app,
  the first witnessed live write (app → config → fork hot-reload → keyboard →
  board pulse → remove → sync.sh). Tag `v0.5-the-pen`.
- **Step 7 — the summon spell**: build the m-a-c-h-i-n-e-s-p-i-r-i-t bind
  THROUGH the app's own editing; typing it opens MachineSpirit.app; the fork's
  letter-accretion wordmark builds as you type. Tag `v0.6-summoned`.
- Cached this session: **#37** per-keystroke pulse.

## Re-entry (fresh session)

Read VISION → CLAUDE → HANDOFF-NOTES → this log → CHECKPOINTS, then
`git log --oneline -15`. Last checkpoint: **[P2.6] / v0.4-sovereign-driver**.
Repo clean, 153-node live config, fork + board running. Resume at Step 6b.
