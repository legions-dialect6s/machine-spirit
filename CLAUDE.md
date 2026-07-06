# machine-spirit — agent handoff

This repo is the owner's **entire macOS environment as code**: launcher,
keybinds, window/menu-bar behavior, terminal, and the hotkey-window splash.
If you are an agent session working on any part of the Mac UI, this file is
your contract. Read it before touching anything.

> **Forward-looking design cache:** [`HANDOFF-NOTES.md`](HANDOFF-NOTES.md) holds
> the roadmap/design intent for the future machine-spirit *app* (node-graph tool)
> and the load-bearing notes for finalizing the busy-pane shield. Read it before
> any work that touches the shield or the app's direction.
>
> **Manual onboarding surface:** [`MANUAL-WIRING.md`](MANUAL-WIRING.md) is the
> checklist of click-through-the-UI steps a human still has to do by hand (the
> consent gates + iTerm plist settings `install.sh` can't script). It doubles as
> the spec for what the app must later auto-configure or guide — read it before
> touching installer/onboarding automation.

## Philosophy

1. **The repo is the canonical artifact.** No config change is "done" until it
   is captured here. Live configs are the source of truth for *content*;
   the repo is the source of truth for *existence*. `scripts/sync.sh` pulls
   live → repo; `install.sh` replays repo → fresh Mac, idempotently.
2. **Portable by construction.** Never hard-code a username or home path in a
   committed file — sync templating rewrites `$HOME` to `__HOME__` on capture
   and expands it on install. Anything path-like you add must survive a clone
   onto a different user account.
3. **Public repo. Zero secrets. Always.** `.gitignore` blocks secret-bearing
   files and a gitleaks pre-commit hook scans every commit
   (`git config core.hooksPath .githooks` must be set). Screenshots go in
   `docs/` only after redacting username, hostname, and IPs. If a file
   *might* hold a token, it does not get committed.
4. **Runtime-light, pre-rendered assets.** Expensive generation happens once,
   at build time, and the rendered artifact is committed (see
   `shell/splash/banners/` — TTF → PNG → block art, all offline). Runtime
   dependencies stay minimal and every one of them is declared in the
   `Brewfile` with a comment saying what it's for. Generation-only tools are
   committed under a `tools/` dir next to their assets, and listed in the
   Brewfile as commented-out optional lines.
5. **Reduce window overflow.** A standing design goal: fight macOS's unbounded
   window pile-up (the owner considers it a real weakness vs. Windows). When
   adding a subsystem, prefer *one summonable/placed surface* over *N stray
   windows*: place windows on the grid rather than let them scatter, pull an
   app's windows forward together, gather ephemeral things (like detached tmux
   sessions → `sheol`) into one ledger you actively clear. If a feature would
   spawn windows without bound, that's a smell — give it a single home.

## Subsystem map

| Area | Where | Notes |
|---|---|---|
| Launcher (Leader Key) | `config/leader-key/` | Caps Lock → F19 via Karabiner; nested vim-style tree |
| Window management | `config/leader-key/` + `bin/win-lerp.applescript` | Rectangle via `rectangle://` URL scheme; spatial key grid, animated resize |
| Key remaps | `config/karabiner/` | captured JSON |
| Terminal | `config/iterm2/` + `shell/` | color scheme, aliases, inline-image tooling |
| Hotkey splash | `shell/splash/` | see its header comments; heavily conventioned |
| App helpers | `bin/` | web-jump.applescript is THE script for all site tab-jumping (never add per-site scripts); plus win-lerp, site-home, screenshots/ |
| OS tweaks | `scripts/macos-defaults.sh` | reversible `defaults` writes only |
| Deps | `Brewfile` | the ONLY dependency manifest |

## Conventions when adding or changing a subsystem

- Add runtime deps to the `Brewfile` with a one-line comment. Optional or
  build-only deps go in commented-out.
- Document the subsystem as a section in `README.md` (feature bullet up top,
  detail section below, showcase image in `docs/` if visual).
- Shell behavior is sourced from `shell/aliases.zsh` — never ship a whole
  `.zshrc` (it collects secrets). Hotkey-window-only behavior gates on
  `ITERM_PROFILE == "Hotkey Window"` (env var set by iTerm at launch;
  "Send text at start" runs too late — do not use it for env vars).
- iTerm profile settings live in the plist, which is NOT captured; anything a
  subsystem requires from the profile (window size, blinking text, hotkey)
  must be documented in README → Terminal splash → Wiring, and applied by the
  user in the Settings UI. Do not edit iTerm's plist while iTerm runs —
  changes get overwritten on quit. `defaults write` for advanced keys
  (e.g. `timeBetweenBlinks`) is acceptable.
- The hotkey window only adopts profile Rows/Columns when the window is
  recreated (fully close it, then re-summon). Remember this before debugging
  "my change didn't show".

## Splash-specific invariants (shell/splash/)

- Layout budget: the whole splash must fit the hotkey window (currently
  39 rows × 125 cols) with the prompt on the last row. Every element is
  width-guarded; art taller than the budget auto-drops the banner. If you add
  content, re-verify: no visible line > window columns, total rows ≤ rows−1.
- The typewriter emits ANSI escape sequences atomically — any new animation
  must preserve byte-fidelity of the final output (test: captured output of
  animated == unanimated).
- fastfetch logo files: `$1`/`$9` are color placeholders; literal `$` must be
  escaped as `$$`. `$2` is the blink color.
- Everything randomized must also be silence-safe: sourcing
  `shell/aliases.zsh` in a normal (non-hotkey) pane must produce ZERO output.
  This is the first test to run after any change.

## Testing checklist (run before committing shell changes)

```zsh
# 1. silence in normal panes
out=$(env -u HOTKEY_PANE ITERM_PROFILE="Default" zsh -c 'source ~/projects/machine-spirit/shell/aliases.zsh' 2>&1); [[ -z $out ]]
# 2. splash renders in-budget (rows/width) for every logo in logos/
# 3. no secrets: gitleaks runs via the pre-commit hook
```

## Editing a keybind / config — the flow that actually works

`sync.sh` is **pull-only, live → repo**, and it only touches things that already
exist: it captures the *live* Leader Key config, and for `bin/` it refreshes
*only files already tracked in the repo* (it does not discover new scripts in
`~/bin`). So editing the repo copy of `config/leader-key/config.json` directly is
a trap — the next `sync.sh` overwrites your edit with the untouched live config.

Correct order when adding/changing a bind:

1. **Edit the LIVE Leader Key config** (`~/Library/Application Support/Leader Key/config.json`)
   — that's the content source of truth. Don't clobber existing binds; back it up first.
2. **New script?** Copy it into the repo's `bin/` **once** manually (repo = source
   of truth for *existence*). It has to be tracked before `sync.sh` will keep it fresh.
3. **Reload Leader Key** with `~/bin/reload-leaderkey.sh` — it does NOT reliably
   hot-reload, so an edited bind stays STALE until the app restarts. Any tool or
   automation that edits the config must call this afterward, or the user will
   test a change that hasn't taken effect. (This becomes automatic once the
   node-graph app owns Leader Key — see [`HANDOFF-NOTES.md`](HANDOFF-NOTES.md).)
4. **Then run `./scripts/sync.sh`** to capture live → repo (it templates `$HOME` → `__HOME__`).
5. Update `README.md`'s keybind tables in the same commit.

Mirror existing path style in the live config: inline commands use `~/bin/...`
(tilde survives sync untouched); absolute `/Users/...` paths get templated to
`__HOME__`. Leader Key's serialization is `"key" : "value"` (spaces around the
colon) — prefer a surgical string edit over a full re-serialize so the repo diff
stays minimal.

**Known Leader Key limitation — `l k` (open settings):** menu-bar apps don't
reliably pop their settings window from `open -a`, so `l k` only works if the
settings window is already open; from cold you still need a manual ⌘, once
Leader Key is focused. Do **not** hack around this — it's slated to be fixed
properly when Leader Key is forked into machine-spirit and we own the
settings-open behavior. Just documented, not worked around.

## Commit & sync flow

```bash
./scripts/sync.sh     # capture live configs first if you changed any
git add -A && git commit   # hook scans; keep commits per-subsystem
git push
```
