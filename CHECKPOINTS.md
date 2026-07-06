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
