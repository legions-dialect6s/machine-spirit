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
