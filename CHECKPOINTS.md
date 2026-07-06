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
