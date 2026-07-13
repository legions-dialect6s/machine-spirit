# CHECKPOINTS — the ratchet ledger

Phase 1 builds the machine-spirit app beside the loved environment-as-code
system, never through it. Every step ends in a working, committed, restorable
checkpoint recorded here. A half-wired cathedral is failure; a smaller finished
altar is success.

## Restore doctrine

Phase 1 **never writes the live system** — not Leader Key's live config, not
Karabiner, never `sync.sh`. So "restore the loved state" is purely a git
operation; the live Mac never needs undoing. Each entry below records the exact
command to return to that state.

**Phase 2 amends the boundary deliberately** (owner's Phase-2 charter): live
writes are permitted through exactly two doors — the write-back machinery
(gate-green precondition, backup, validate, atomic swap) and supervised swaps
with the owner present and a one-line rollback documented BEFORE the swap.
Ad-hoc live edits stay forbidden; after any supervised live change, `sync.sh`
keeps the repo mirror true. Karabiner's live config stays untouched entirely.
Phase-2 restore entries therefore record BOTH the git command and, where a
live surface was touched, the live rollback.

If pushed history must also rewind: `git push --force-with-lease` — **after
owner confirmation only**.

---

## Ledger

### v0.1-stable-config — the pre-app loved state `[P1.1]`

The pre-app loved state, everything working: launcher, window grid, splash,
tmux protection + sheol, and the sigil assets (`assets/icon.png`,
`assets/icon_transparent.png`) captured into the repo.

**Restore:** `git stash -u && git reset --hard v0.1-stable-config`
(repo only — Phase 1 never writes the live system, so the live Mac needs no
undoing.)

### Forks vendored + building `[P1.2]`

LeaderKey (`16bcb30`, MIT) and Rectangle (`7d6b4c5`, MIT) vendored as squashed
subtrees under `forks/`; **both build from source** with ad-hoc signing — exact
commands in `forks/FORK-NOTES.md`. Stale README fork-strategy paragraph fixed;
`.gitignore` extended for Xcode debris.

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.2] below>`
— or check out the commit whose subject starts with `[P1.2]`.

### v0.2-fork-baseline — kit: model + lossless importer + round-trip gate `[P1.3]`

`kit/MachineSpiritKit` (UI-free Swift package, headless `swift test`): Node
model with native group+action duality, lossless Leader Key importer
(unknown fields survive in `extras`), serializer, derived inertness via
injectable probes, `GraphViewState` sidecar type. THE MECHANICAL WITNESS:
14 tests green, including canonical round-trip of the repo fixture and
unknown-key survival. Live config (153 nodes) also proven to round-trip
canonically, read-only. This gate stays green at every checkpoint from here.

**Restore:** `git stash -u && git reset --hard v0.2-fork-baseline`
**Re-verify:** `cd kit/MachineSpiritKit && swift test`

### The witness stands — tree renders the imported config `[P1.4]`

`app/MachineSpirit`: SwiftUI app (macOS 26, kit as local package, project
generated from committed `project.yml` via XcodeGen). Imports the live config
read-only on launch; renders the full tree — key glyph, type badge, value
summary, inert rows ghosted with reason on hover. One `@Observable` AppState
owns model + selection + viewMode; both views are projections of it.

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.4]>`
**Re-verify:** `cd app/MachineSpirit && xcodegen generate && xcodebuild
-project MachineSpirit.xcodeproj -scheme MachineSpirit -configuration Debug
-derivedDataPath DerivedData build && open
DerivedData/Build/Products/Debug/MachineSpirit.app`

### The altar stands — node-graph canvas over the same model `[P1.5]`

`GraphView`: SwiftUI Canvas with drag-pan + pinch-zoom, deterministic
tidy-tree layout (kit `TidyTreeLayout`, headless-tested: deterministic, every
node placed, single-child chains compressed so `q-u-i-t` reads as a route).
Glyph language: action = filled core, group = halo ring, both = both (dual
wears magenta — reserved for the necromantic), inert = ashen ghost. Header
label toggles worlds until Tab lands in [P1.6]. Owner eyeballed it live.
Owner's far-look ideas cached as HANDOFF-NOTES #22–25.

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.5]>`
**Re-verify:** kit `swift test` (19 green) + build & open the app, click
"the witness" to cross to the altar.

### Tab-switch carries the selection across worlds `[P1.6]`

Tab toggles tree ⇄ graph via a retained local NSEvent monitor (the unretained
token was a real caught bug — monitor died instantly). Landing behavior:
tree unfolds ancestors (`expandedIDs` in AppState, tree rebuilt on
DisclosureGroups) and scrolls to the selection; graph centers + sane-zooms on
it. Selection lives ONLY in AppState. Owner-verified live ("works :)").

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.6]>`
**Re-verify:** build & open; select on either side; Tab across.

### The sigil as app icon + F19 indicator (Route A) `[P1.7]`

App icon: asset catalog built from `assets/icon.png` (sips 1254 → 16…1024);
Dock and window wear the sigil. Summon indicator: the LeaderKey fork's Mini
theme renders `assets/icon_transparent.png` when idle instead of the plain
dot — fork builds green. Altar got a zoom slider, ⌘=/⌘-, and a wide zoom
clamp (owner request). **The brew-cask Leader Key remains the daily driver.**

**Supervised demo (owner present only):** quit the cask app → open
`forks/LeaderKey/DerivedData/Build/Products/Debug/Leader Key.app` → tap F19.
**Rollback:** quit the fork → `open -a "Leader Key"` — nothing else changes;
both read the same live config (read-only for our purposes).

### The wordmark builds letter by letter `[P1.8]`

In the fork's Mini indicator: as keys land, the summon chain assembles —
dim trail, bright head, per-letter spring-in; the box grows leftward from its
bottom-right anchor (Combine subscription on navigationPath/display). Idle
still shows the sigil. Cheap and atomic: text + one spring, no heavy effects.
The full m-a-c-h-i-n-e-s-p-i-r-i-t flourish needs a live-config bind (behind
the Phase-1 live-system boundary) — the accretion mechanic completes the step;
the flourish waits for the owner demo / Phase 2.

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.8]>`
**Re-verify:** rebuild the fork (command in FORK-NOTES.md); supervised demo
as documented under [P1.7].

### sheol-core extracted; TUI rewired; parity proven `[P1.9a]`

`bin/sheol-core` (zsh): policy-free verbs — `list` (byte-identical to the
TUI's \x1f format), `list --json`, `revive`, `detach`, `kill`; exact-match
`=name` targeting; exits 0 on expected-empty; never dialogs; forwards
TMUX_TMPDIR into revive's new window. The TUI's four call sites rewired
(bash-3.2-clean; trap/redraw/signature machinery untouched). Proven on an
isolated socket: list parity byte-for-byte, JSON valid (incl. a space in a
session name), detach 1→0, revive 0→1 in a fresh window, kill exiles.
War story renewed: `$TMUX` must be UNSET in tests — a client inside a
session ignores TMUX_TMPDIR (three stray sessions briefly landed on the real
server; removed by exact name; nothing else touched).
This checkpoint stands alone: if 9b dies, the TUI works and the core exists.

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.9a]>`
**Re-verify:** run the scratch test (unset TMUX; TMUX_TMPDIR=$(mktemp -d));
owner glances at repo TUI on the real socket, read-only.

### sheol lives in the graph `[P1.9b]`

SheolService (app): all tmux through `bin/sheol-core`, never direct; 2s poll.
The `t-m-u-x` bind (found by value, not key path) grows into the living dual
node while spirits wander — ring AND core — with per-wanderer children
(name · command · quiet-for) carrying revive and banish verbs; banish honors
the ◆◆◇ ward (arms per node, decays ~2s). Conditional visibility: empty sheol
= the plain imported bind. Proven on an isolated socket end-to-end: footer
probe showed 2 wanderers and 152→158 grafted nodes. Real-socket use is
revive-only until the owner demo.
Tag `v0.3-phase1` is deferred until the owner has driven sheol live —
findability on the altar was poor (tidy-tree sprawl), fixed in the next slice.

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.9b]>`
**Re-verify:** throwaway socket + launch app binary with TMUX_TMPDIR (unset
TMUX first); footer shows wanderers; strike r / d·d·d on test spirits.

### Altar v2 — radial 360°, both views side by side, walk by key `[P1.10]`

Owner-driven redesign: directory and node graph visible together (focused
pane marked; Tab switches); UI copy de-lored (directory / node graph /
refresh — theme stays where it's earned: sheol). RadialLayout in the kit
(360° from center, arc pressure with cap, chains as spokes; 23 tests green).
Constant screen-size nodes + semantic zoom (depth bands bloom as you zoom).
Letter-walk in both views (Leader Key grammar: 1→1→first-third), Esc root,
⌫ up, ⏎ strike, ⌘R refresh, ⌘=/⌘- zoom — one retained key monitor. Scroll
pans, ⌘scroll zooms (NSView catcher so the directory keeps its own scroll).
Selection glides to center, smoothstep (win-lerp lineage).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.10]>`
**Re-verify:** build & open; type `1 1 1`; scroll/⌘scroll; Tab panes.

### Spirits leave the config graph (owner ruling) + drive polish `[P1.11]`

Owner ruled the living sheol node OUT of the config graph — that surface is
for binds and commands (HANDOFF-NOTES #26 🔒). Graft + in-graph strikes
reverted (history keeps them at [P1.9b]–[P1.10]); sheol-core, SheolService,
and the footer nag remain as plumbing for the future ledger surface (#15).
Same slice: twisty deterministic cables, dead-space click deselects,
walking STAYS at branch ends (Esc/click to reset), ⌘=/⌘- zoom anchors on
the selection, ⌘R breathes the graph + flashes "✓ re-imported N nodes".

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.11]>`
**Re-verify:** build & open; walk to a leaf and keep typing (stays); click
dead space (clears); ⌘R (breathe + flash).

### Circuit-board traces, path glow, real scroll, the sheol door `[P1.12]`

Edges route like circuit traces in polar space (spoke out → arc along a
per-trace junction ring → spoke to child; launch-deterministic variation).
Selection lights the path: center→selection trace + its children glow,
the rest recedes. Scroll rebuilt as a window-level monitor scoped to the
graph pane: mouse wheel zooms AT THE CURSOR, trackpad pans, ⌘-scroll zooms
(directory scrolling untouched). Header gains "⌁ sheol" — launches the
ledger terminal; the config surface carries sheol's commands, never its
live state (#26 doctrine).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.12]>`
**Re-verify:** build & open; wheel-zoom over the graph; walk `t` (path
glows); click "sheol" (ledger window opens).

### The board lives — growth, sway, taper, typewriter, cascade `[P1.13]`

TimelineView-driven canvas (20fps, heat-conscious): traces GROW from the
center to the rim on boot/refresh (trimmed paths, staggered by radius, nodes
fade in behind their trace); at rest the lines sway faintly and stir when
the viewport moves (vines in water; smooth sibling-staggered cubics along
junction rings — no hard corners); widths taper with depth. The header
wordmark types itself in (sheol's reveal); the directory cascades row by
row on boot/refresh. Zoom bar de-chromed. Kit: command display names skip
wrapper plumbing (`run-quiet.sh …/ss-menu.sh` → `ss-menu`; 24 tests green).
Cache: #29 aesthetics-as-parameters 🔒, #30 drag-and-drop design.

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.13]>`
**Re-verify:** build & open (growth + typewriter + cascade); ⌘R replays
them; pan hard and watch the lines stir, then settle.

### Identity colors, icons, legible labels, the leader-key parent `[P1.14]`

Owner palette: window-tiling mint (174,222,203), folder ice (217,241,254),
command terminal-green, groups phosphor, duality magenta; app nodes tinted
by their icon's dominant color with the real icon in the disc (folders get
the folder icon, commands the terminal's — IconStore caches both). Traces
run parent→child color gradients. Labels: bigger, brighter, backing pill,
placed radially OUTWARD into the empty space (the anti-overlap 80%; #31
holds the 20%). Sway made visible (screen-space, detuned sines); subtree
glow (whole branch lights, not just children); gentler geometric taper.
Directory: ⇪ leader-key parent row (future: more leaders), children cascade
too, opens at min width, collapsible from the header; title centered; root
node wears ⇪. Cached #31 (label-aware rerouting) + #32 (SwiftTerm ledger
pane recommendation).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.14]>`
**Re-verify:** build & open; colors/icons on the rim; select `t` (whole
branch glows); collapse/restore the directory.

### Self-explaining labels, still-at-rest board, leaf shells `[P1.15]`

Nodes say what they do (kit displayName + tests): `open app Claude`,
`open folder projects` / `~/Documents/…` (home-anchored, username never
shown), `invoke ss-menu`, `window maximize`, `open url …`. The board is
perfectly STILL at rest — the render clock pauses when calm (no idle
jitter, no idle heat) and wakes on the first disturbance; sway is
movement-only and decays. Growth ~45% faster (0.85s). Labels back to grey,
pills flush with the disc. Crowded leaves stagger across three shells
(RadialLayout, deterministic). Esc glides home (root centered, default
zoom). Directory idealWidth narrowed (note: HSplitView divider position
persists across relaunch via window restoration — drag it once).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.15]>`
**Re-verify:** kit `swift test` (25 green); open, wait 4s — board frozen
still; scroll — it stirs; Esc from deep — glides home.

### Directional flow, readable spread, gates, spelled words, MB4 `[P1.16]`

The lines react to the MOVEMENT itself: pan velocity feeds a flow vector
(blended, capped) and traces trail against the current, then relax — no
plugin, just physics-flavored state. At label-readable zooms the layout
SPREADS: leaf arcs sized by label width (kit RadialLayout gained a
leafWeight closure), wider rings — read everything on screen. Single-child
waypoints are now "gates" (GTE badge) — distinguished from true groups in
both views. Chain-end leaves wear their spelled word in a box off the disc
(q-u-i-t → «quit»; the radial label clears it). Max zoom-out floored at
0.08 so the first graph stays findable. A second leader graph (mouse
button 4: q→Spotlight, e→wallpaper) renders beside the board as an
HONESTLY-UNBOUND exhibit of the multi-leader future (#33).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.16]>`
**Re-verify:** kit tests (25); fling the board and watch traces trail the
motion; zoom past 0.5 — layout spreads; find «quit»/«tmux» boxes; the MB4
exhibit sits east of the rim.

### Interlocked stagger, drag-and-drop, favicons, the embedded ledger `[P1.17]`

The (*-_) stagger understood and shipped: all-leaf clusters pack into
offset columns (kit `stackLeafClusters`) so labels interleave — more reads
at further zoom-out (label threshold lowered to 0.42). Jitter killed the
right way: ZERO shimmer during viewport motion (board moves rigidly, drift
trails the current), the sine rings only after motion stops. DRAG AND DROP:
drag a node to move it (drag space to pan — decided by what's under the
cursor), positions persist via the GraphViewState sidecar in App Support,
a "sort" button restores the radial order. FAVICONS: web-jump nodes fetch
and wear their site's favicon (google s2, cached) and tint their node +
trace by it; app/folder/terminal icons now prominent (0.85). MB4 exhibit
listed in the directory; selecting a parent auto-opens its children.
SWIFTTERM LANDED (SPM, pinned 1.5.0; vendor when we patch — #32): the
sheol button now opens the REAL TUI in an embedded right-hand pane —
commune/ward and all — with pop-out-to-iTerm (tmux lets spirits change
bodies) and in-app close (pkill; the TUI's traps exit clean).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.17]>`
**Re-verify:** kit tests (26); drag a node, relaunch — it stayed; click
sheol — the ledger lives in the pane; web nodes wear favicons.

### Nothing hides `[P1.18]`

Pruning gone — every node at every zoom (smaller, never absent; labels,
icons, lines always). Far-click centering fixed (was centering against the
undragged layout). Roots drag their whole tree; ⌘-click multi-select,
⌘-drag rubber band, group drags. Viewport persists with positions (quit
too). Sway retired by owner verdict. Chain boxes read q»uit. Traces bow
around nodes. Directory rows wear icons + identity colors. Command→app
icon intelligence. Ledger pane: real PATH + the owner's hacker.itermcolors
parsed at runtime. Honest disabled +/− until write-back. Icon re-registered.
Cached: #34 gate-latch/merge on drag-close; #35 learn the owner's manual
layout as the auto-organize objective; #36 fire-animation when a bind runs
(needs the LK fork to ping the app — URL scheme — future).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.18]>`
**Re-verify:** zoom way out — everything still there, smaller; ⌘-drag a
box around a cluster and drag it; open sheol — tmux found, iTerm colors.

### Corrections: curves back, sway done RIGHT, sheol is a pane `[P1.19]`

Two over-rotations undone: the cables ARC again (per-trace side/swell +
obstacle bow + sway flex), and the sway is restored the way it was asked
for — rigid while the hand moves, then the lines flex with the throw's
energy at 60fps (no stepping, no jitter), ringing down to true stillness
(clock pauses). Sheol is now a first-class pane: Tab cycles directory →
graph → sheol (Tab handled BEFORE terminal passthrough so it can't trap),
focusing it hands the keyboard to the TUI (keys finally register — the
app-wide walk monitor was eating j/k/r/d/q), clicking it focuses, leaving
resigns. The TUI gained `n` — birth a new spirit in the land of the living
(tmux-launch via script-dir resolution, bash-3.2-clean).

**Restore:** `git stash -u && git reset --hard <commit tagged [P1.19]>`
**Re-verify:** fling → release → lines flex then still; Tab thrice cycles
all three panes; walk the ledger with j/k, press n — a new window with a
living spirit.

---

## Phase 2 — the wiring

### Codex hardening adopted; the boundary made true `[P2.1]`

Four commits ([P2.1b]–[P2.1d]; [P2.1a]'s shell hardening turned out to be
already committed pre-phase as `6d77ef2` — quoted-form injection fixes,
pidfile over pkill, \x1f parse delimiter — nothing to re-adopt):
- **[P2.1b]** app lifecycle: `AppState.shutdown()` (monitors, observer,
  glide/poll tasks), atomic sidecar writes, pidfile-guarded
  `LedgerTerminal.endTUI()` (broad pkill only as stale-file fallback),
  nonisolated `glyphColor`.
- **[P2.1c]** the losslessness boundary: JSONDecoder silently keeps the
  first of duplicate keys (empirically proven — the plan assumed it threw).
  Made true, then documented: escape-aware raw-byte pre-scan refuses with
  `ImportError.duplicateKey`; kit gate 26 → 28 tests; kit README born.
- **[P2.1d]** sheol `sig()` joints ride \x1f (a name carrying `|`/`:` can no
  longer suppress a redraw); proven on a throwaway socket with spirits named
  `pipe|spirit` and `colon:ghost`. Both Codex non-blockers thereby resolved.

⚠ **Standing hazard:** repo `bin/tmux-sheol.sh` + `bin/sheol-core` are AHEAD
of live `~/bin` (this fix + P1.19's `n` key). Refresh live from repo in the
Step 3 supervised window BEFORE any `sync.sh`, or sync clobbers the repo copy.

**Restore:** `git stash -u && git reset --hard <commit [P2.1d]>` (repo only —
nothing live touched this step).
**Re-verify:** kit `swift test` (28 green); app builds
(`xcodegen generate && xcodebuild … build` per [P1.4]); sheol smoke on an
isolated `TMUX_TMPDIR` socket with `$TMUX` unset.

### Sort made non-destructive — named layouts, radial ⇄ hand `[P2.2]`

Two named layouts replace the destructive sort: **hand** (the owner's
arrangement, persisted as `layouts.hand` in the sidecar, edited by drags in
hand mode) ⇄ **radial** (the computed mandala — never stored, always
recomputable; drags there are a scratch that "sort" clears). Toggle lives in
the zoom-controls strip. Kit schema v2 (optional `layouts`/`activeLayout`)
loads old sidecars gracefully; nil `activeLayout` migrates `nodes` into
`layouts.hand`. Proven against the owner's real 156-position sidecar:
migrated, projected to radial, hand entry survived, restored hand-active.
Recovery source if anything was ever lost:
`~/Library/Application Support/MachineSpirit/graph-view.hand-layout-2026-07-06.json`.

**Restore:** `git stash -u && git reset --hard <commit [P2.2]>` (sidecar is
app-owned state; the dated backup above is its own safety net).
**Re-verify:** kit `swift test` (29 green); build & open; toggle radial ⇄
hand — the arrangement survives round trips; drag in radial → "sort" appears
and clears only the scratch.

### Hot-reload lands in the fork (implementation) `[P2.4]`

`ConfigFileMonitor` in the LeaderKey fork: DispatchSource watch on the live
config, 300ms debounce, re-arms on the path after every event burst so the
atomic-swap write ritual can't kill the watch. Wired at launch; re-watches on
configDir changes. Proven headlessly (3 XCTests incl. rename-survival); the
supervised live demo happens in the Step-3/4 owner window, and
`reload-leaderkey.sh` goes legacy only then.

**Restore:** `git stash -u && git reset --hard <commit [P2.4]>`
**Re-verify:** fork test plan green (`xcodebuild … -testPlan TestPlan test`).

### ⚠ Incident: fork tests ate the live config — sandboxed + restored `[P2.4x]`

Upstream's own test suite deletes the REAL config home; one full-plan run
destroyed the live config. Restored from the repo mirror (151 nodes, atomic);
fork patched so `defaultDirectory()` sandboxes itself under XCTest; full plan
re-run green with the live config byte-identical. Full story: SESSION-LOG.

**⚠ OWNER WINDOW ACTION (staged):** the live config had drifted ~2 nodes
ahead of the repo and they exist now ONLY in the running cask app's memory.
Any LK settings edit pops the "changed on disk" conflict alert — choose
**Overwrite** (memory → disk), then `./scripts/sync.sh`. If LK restarts
first, the 151-node repo state is the floor.

**Restore:** repo-side `git reset` as usual; live-side restore command (the
one used): `sed "s|__HOME__|$HOME|g" config/leader-key/config.json > /tmp/lk
&& mv /tmp/lk "$HOME/Library/Application Support/Leader Key/config.json"`.

### Write-back machinery, proven against temp targets `[P2.6a]`

`ConfigWriter` in the kit: gate-green precondition (refuses with divergence
paths), timestamped backup outside the repo, temp-write + re-import
validation (the artifact is proven before it exists at the real path),
rename(2) atomic swap, node-level change report. Serializer/backup-dir
injectable; target path parameterized — nothing live is ever a default.
Kit gate 36 green, including fault-injected corrupted serializes and the
full ritual on a copy of the real live config. Stands alone: if 6b dies,
the machinery exists and nothing live was touched.

**Restore:** `git stash -u && git reset --hard <commit [P2.6a]>`
**Re-verify:** `cd kit/MachineSpiritKit && swift test` (36 green).

### The fired ping, app side — scheme registered, wave staged `[P2.5a]`

`machinespirit://` registered and proven resolvable (LaunchServices accepts
`open -g "machinespirit://fired?path=q/u/i/t"`); `fireBind` resolves the key
route silently (unknown paths are no-ops), and the wave rides the real
traces: bright front center → node, fading trail, arrival flash ring — all
knobs in `FirePulseKnobs` (#29, off switch included). Fork-side firing is
deliberately unbuilt: §2 preview-before-motion — the owner sees the one-node
demo first, then the scheme gets wired end-to-end.

**Restore:** `git stash -u && git reset --hard <commit [P2.5a]>`
**Re-verify:** build & open the app; `open -g "machinespirit://fired?path=q/u/i/t"`
— the q-u-i-t route pulses once.

---

## THE OWNER WINDOW — supervised runbook (Phase 2, staged in order)

Everything below needs the owner at the keyboard. Nothing here is started
without them; each item names its rollback BEFORE it runs.

**0. Recover the drifted binds ([P2.4x] aftermath).** The live config on
disk is the 151-node repo restore; the cask app's memory holds ~2 newer
binds. Open Leader Key's settings, make ANY trivial edit — its "config
changed on disk" alert appears — choose **Overwrite**, undo the trivial
edit, then `./scripts/sync.sh` and commit. (If LK restarted since 22:49,
skip: memory is gone, 151 is the truth.)

**1. Refresh live ~/bin from the repo.** `cp bin/tmux-sheol.sh bin/sheol-core ~/bin/`
— repo is ahead (P1.19's `n` key + P2.1d's sig fix). Do this BEFORE any
future sync.sh so sync can't clobber the repo copies.

**2. The pulse preview (§2 nod).** Open MachineSpirit.app, run
`open -g "machinespirit://fired?path=q/u/i/t"` — the board answers. Owner
nod → fork-side firing gets built (machinespirit://fired on every executed
action, non-blocking, silent-failing). Veto → knobs/redesign, no fork work.

**3. The swap ([P2.3]).** Pre-swap verification already done (fork rebuilt
from FORK-NOTES incantation; sigil + wordmark patches intact and the fork's
ONLY divergence besides hot-reload + test sandbox; kit round-trip green on
the live config). **Rollback, documented first:** quit the fork; `open -a
"Leader Key"` — the cask app stays installed all session. Sequence: quit
cask LK → launch `forks/LeaderKey/DerivedData/Build/Products/Debug/Leader
Key.app` → grant Accessibility/Input Monitoring if macOS asks (ad-hoc
signature differs from the cask's — expect TCC to treat it as new; guide,
never auto-flip) → disable cask launch-at-login, enable the fork's → live
smoke test, owner driving: browser cycle, spatial grid, q-u-i-t,
screenshots, t m u x. Any regression → rollback immediately, record the
wall. Clean pass → tag `v0.4-sovereign-driver`.

**4. Hot-reload live verify ([P2.4] close).** With the fork driving: hand-edit
the live config (add a trivial bind), watch the fork pick it up WITHOUT
restart; remove it; `sync.sh`. Mark `reload-leaderkey.sh` legacy in README.

**5. Write-back 6b + the ceremony (7).** Only after 3+4 stand: the +/−
buttons come alive over ConfigWriter ([P2.6a], already armored and tested);
first live write witnessed end-to-end (app → config → fork hot-reload →
keyboard → board pulse), tag `v0.5-the-pen`; then the
m-a-c-h-i-n-e-s-p-i-r-i-t bind through the app's own editing, tag
`v0.6-summoned`.

### The swap begins — rollback documented FIRST `[P2.3]`

Supervised, owner present. The fork becomes the runtime driver so the
fired-pulse loop closes on real keystrokes.

**ROLLBACK (one move, cask never uninstalled):**
```
osascript -e 'quit app "Leader Key"'   # quits whichever is frontmost-named
pkill -f 'DerivedData/Build/Products/Debug/Leader Key.app'   # ensure fork gone
open -a "Leader Key"                    # cask app back as driver
```
The cask app stays in /Applications and stays a login item all session, so a
reboot alone also restores it. Nothing about the live config or Karabiner is
touched by the swap.

**Deliberate scope:** this step does the RUNTIME swap only (cask quit, fork
launched, permission granted, smoke test). Launch-at-login persistence is
NOT flipped in the same breath — it's deferred until the fork has proven
itself over real use, keeping rollback trivial (just relaunch the cask). Both
apps share the bundle id `com.brnbw.Leader-Key`, hence the same F19 activation
and settings; only the code signature differs (cask Developer-ID vs fork
ad-hoc), which is why a fresh Accessibility grant is the likely gate.

### The loop closes — a real keystroke pulses the board `[P2.5e]` 🎇

WITNESSED live, owner driving (2026-07-09, ~23:36). With the fork as the
runtime driver, pressing a leader bind (`⇪ c l`, `⇪ s a`) fired
`machinespirit://fired?path=…` and the board pulsed that exact route. The
full chain proven end to end: **app → config → fork → keyboard → board.**
Design cache #36, real.

Two snags cleared to get here, both worth remembering:
- **Duplicate bundle id (`com.brnbw.Leader-Key`) makes `open <fork path>`
  unreliable** — LaunchServices bounced it to the cask in /Applications, so
  the fork appeared to run but the cask actually drove (binds worked, nothing
  pulsed). Fix: launch the fork by its **direct binary path**, cask killed by
  pid first. The permanent fix (its own bundle id / identity) is the fork's
  next real chunk of work.
- **`strings`/`nm` surface no Swift string literals here** (even known ones
  like "Configuration file changed on disk") — binary forensics lied; only
  runtime proof counts.

**Restore / rollback:** unchanged from [P2.3] — quit fork, `open -a "Leader
Key"`. The runtime swap is still session-only; launch-at-login persistence
and the fork's own identity remain deferred, deliberately.

### v0.4-sovereign-driver — the fork's own identity, permanent driver `[P2.6]`

The deferrals above landed: the fork is `com.machinespirit.leader-key`
("MachineSpirit Leader Key"), installed at `~/Applications`, launched at
login via its own LaunchAgent, prefs seeded from the cask (F19 activation).
The cask is NOT running, off login startup, TCC reset — kept in
/Applications for rollback only. Ad-hoc signing caveat: every fork REBUILD
re-prompts Accessibility (stable personal-team signing noted in FORK-NOTES,
unbuilt). Full live-system state: SESSION-LOG → "CURRENT LIVE-SYSTEM STATE".

**Restore / rollback (replaces [P2.3]'s):**
```
launchctl bootout gui/$(id -u)/com.machinespirit.leader-key
pkill -f 'Applications/MachineSpirit Leader Key.app'
open -a "Leader Key"     # re-enable cask launch-at-login + Accessibility by hand
```

### The pen — +/− buttons write the live config through the gate `[P2.6b]`

The write-back machinery ([P2.6a]) is wired to the board. `+` aims at the
selected group (selection's parent when a leaf is selected; root when
nothing is) and opens a small form — key, optional label, action type,
value; `−` strikes a selected leaf bind behind a confirm that names it.
Every stroke goes through `ConfigWriter`'s full ritual against the live
config — gate precondition → timestamped backup → temp-write + re-import
validation → atomic swap — then the app RE-IMPORTS the written truth (never
trusts its memory), selects the new node, and pulses its route. The footer
reports node-by-node (`✎ + root/g/n · backup kept`, path on hover) and
speaks refusals in full. Kit grew the pen's grammar (`insertingLeaf` /
`removingLeaf`, pure-value edits that mint ids exactly as the importer
would) — gate 43→44, including the whole add-then-remove ritual run against
a COPY of the real live config, byte-verified untouched.

Guards that matter: inserts refuse duplicate sibling keys and action-carrying
parents (the fork never sees a dual node it can't run); removal is leaf-only;
the unbound MB4 exhibit and the root refuse the pen entirely; a focused text
field owns the keyboard (the walk can't eat typed letters).

**Restore:** `git stash -u && git reset --hard <commit [P2.6b]>`; any written
config restores from `~/.local/state/machine-spirit/config-backups/`.
**Re-verify:** kit `swift test` (44 green); build & open the app; select a
group, `+`, inscribe a throwaway bind; watch the fork pick it up without
restart; `−` it; footer reports both writes.
