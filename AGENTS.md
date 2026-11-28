# AGENTS.md — machine-spirit

`machine-spirit` is its owner's entire macOS environment as code: launcher, keybinds, window and menu-bar behavior, terminal, and the hotkey-window splash. It is co-authored by the owner and several AI coding agents (**Claude**, **Codex**, **Gemini**, and any future session). This file is the one contract for all of them, and [`CLAUDE.md`](CLAUDE.md) only imports it: put rules here, never there. Read it before changing code, configs or docs.

## Read when you touch that area

- [`VISION.md`](VISION.md): design philosophy (*keyboard where keyboard wins, mouse where mouse wins*).
- [`HANDOFF-NOTES.md`](HANDOFF-NOTES.md): design cache for the node-graph app and the busy-pane shield. Read it before touching either.
- [`MANUAL-WIRING.md`](MANUAL-WIRING.md): the consent gates and iTerm settings a human still does by hand; the spec for installer and onboarding automation.
- [`CHECKPOINTS.md`](CHECKPOINTS.md): restore doctrine and checkpoint ledger.
- [`docs/REFERENCE.md`](docs/REFERENCE.md): every keybind, CLI command and wiring detail. [`docs/VISUAL-AUDIT.md`](docs/VISUAL-AUDIT.md): screenshot provenance and privacy audit.
- [`forks/FORK-NOTES.md`](forks/FORK-NOTES.md): what the owned forks change. `forks/LeaderKey/AGENTS.md` and `CLAUDE.md` are upstream's build guide; leave them as upstream wrote them.

## Core invariants

1. **The repository is the canonical artifact.** No config change is done until it is captured here. Live configs (`~/Library/Application Support/Leader Key/config.json`, `~/.config/karabiner/karabiner.json`) are the source of truth for *content*; the repo is the source of truth for *existence*. [`scripts/sync.sh`](scripts/sync.sh) pulls live → repo; [`install.sh`](install.sh) replays repo → fresh Mac, idempotently.
2. **Portable by construction.** Never commit a username or a `/Users/...` path. `sync.sh` templates `$HOME` to `__HOME__` and `install.sh` expands it. Anything path-like you add must survive a clone onto another account.
3. **Public repository. Zero secrets. Always.**
   - `git config core.hooksPath .githooks` must be set; every commit is scanned by `gitleaks` through [`.githooks/pre-commit`](.githooks/pre-commit). If a file *might* hold a token, it does not get committed. Never ship a whole `.zshrc` (it collects secrets): shell behavior is sourced from `shell/aliases.zsh`.
   - Never capture a full-desktop screenshot. Every image in `docs/img/` is tightly cropped or rendered against a clean synthetic backdrop, free of usernames, hostnames and IPs, stripped of EXIF/tEXt/iTXt/tIME metadata, visually inspected, and logged in [`docs/VISUAL-AUDIT.md`](docs/VISUAL-AUDIT.md).
4. **Runtime-light, pre-rendered assets.** Expensive generation runs once, offline, and the rendered artifact is committed (see `shell/splash/banners/`). The [`Brewfile`](Brewfile) is the only dependency manifest: each runtime dependency gets a one-line comment saying what it is for; optional and build-only ones go in commented out; generation-only tools live in a `tools/` directory next to their assets.
5. **Reduce window overflow.** Prefer one summonable, well-placed surface over N stray windows: place windows on the grid, pull an app's windows forward together, gather ephemeral things (detached tmux sessions → `sheol`) into one ledger. A feature that would spawn windows without bound needs a single home.

## Commit and push

- **Stage explicit paths only**, never `git add -A`: other sessions and the owner leave work in this tree. Keep commits per subsystem. Use `Co-Authored-By:` trailers for the agents that took part, and keep docs agent-agnostic: never credit the repository to one agent or provider.
- **Verified work is pushed to `main`.** The gate is [`scripts/push-checkpoint.sh`](scripts/push-checkpoint.sh). Run it directly, or end the commit message with the trailer `Checkpoint: ready` and [`.githooks/post-commit`](.githooks/post-commit) runs it (needs `git config machinespirit.pushCheckpoints true`). It requires a clean tree on `main`, then runs `git diff --check`, `gitleaks` over the outgoing commits, the drift gate below, `swift test` for `kit/MachineSpiritKit` and `tools/ms`, `xcodebuild test` for `forks/LeaderKey` and `xcodebuild build` for `app/MachineSpirit` when those changed, and fast-forwards `origin/main`.
- If the tree holds another session's uncommitted work the script refuses. Run the same checks on your own range by hand and push only your commits; do not stash, commit or revert their files.
- If you changed a live config, run `./scripts/sync.sh` before committing.

## Docs & visuals drift gate

[`scripts/check-docs-drift.py`](scripts/check-docs-drift.py) runs on every push through the gate. Run it yourself first:

```bash
python3 scripts/check-docs-drift.py --range origin/main..HEAD --gate
```

1. **Keybind parity:** every leaf shortcut in `config/leader-key/config.json` is documented in [`docs/REFERENCE.md`](docs/REFERENCE.md), with highlights in [`README.md`](README.md).
2. **Link and asset integrity:** every Markdown link and image in `README.md` and `docs/REFERENCE.md` resolves; every asset in `docs/img/` appears in `docs/VISUAL-AUDIT.md`; PNGs carry no EXIF, text or time chunks.
3. **UI-to-visuals freshness:** a change to a visible surface (`CompactBar.swift`, `NowPlayingMenu.swift`, `StatusItem.swift`, `TypingOverlay.swift`, `GraphView.swift`, `AppsPane.swift`, `Clipboard*.swift`, `tools/ms/`, `shell/splash/`) refreshes its docs and screenshots, or carries a review trailer (`Visuals-Reviewed: current` / `Docs-Reviewed: current`) after you have checked that the existing ones are still accurate.

## Subsystem map

| Area | Path | Notes |
|---|---|---|
| Launcher & menu bar fork | `forks/LeaderKey/` | Owned Leader Key fork: key capture, hold mode, unified status bar, DDC brightness, Now Playing, clipboard panel |
| Overlay & board app | `app/MachineSpirit/` | Accessory app: Core Animation typing overlay, node-graph editor, embedded `sheol`, `Apps` pane |
| Shared Swift package | `kit/MachineSpiritKit/` | Node model, lossless importer/serializer, `ConfigWriter` write gate, radial layout |
| Native CLI & MCP server | `tools/ms/` | Zero-dependency Swift CLI + stdio MCP: windows, displays, binds, `sheol`, Pulse (hourly sample + low-disk alert), OCR+Translate |
| Captured configs | `config/` | Leader Key (`__HOME__` templated), Karabiner (Caps Lock → F19), iTerm2 colors, tmux and launchd plists |
| Window management | `config/leader-key/` + `bin/win-lerp.applescript` | Rectangle through its `rectangle://` URL scheme; spatial key grid, animated resize |
| Helpers | `bin/` | `web-jump.applescript` is THE script for site tab-jumping (never add per-site scripts); `app-jump`, `app-toggle`, `sheol-core`, `tor-session.py`, `screenshots/` |
| Terminal & splash | `shell/` | `aliases.zsh` (silent in normal panes), pre-rendered banners; see the invariants below |
| OS tweaks | `scripts/macos-defaults.sh` | Reversible `defaults` writes only |

When you add or change a subsystem: declare its dependencies in the `Brewfile`, add a feature bullet and a detail section to `README.md` (with a showcase image under invariant 3 if it is visual), and put the full detail in `docs/REFERENCE.md`.

## Editing a keybind or config

`sync.sh` is **pull-only, live → repo**. It captures the live Leader Key config and refreshes only the `bin/` files the repo already tracks. Editing the repo's `config/leader-key/config.json` directly is a trap: the next sync overwrites it.

1. **Edit the live config** (`~/Library/Application Support/Leader Key/config.json`). Back it up first and do not clobber existing binds.
2. **New script?** Copy it into the repo's `bin/` once by hand; `sync.sh` only keeps tracked files fresh.
3. **Reload Leader Key** with `~/bin/reload-leaderkey.sh`. It does not hot-reload reliably, so an edited bind stays stale until then. Any tool that edits the config calls this afterward.
4. **Run `./scripts/sync.sh`** to capture live → repo.
5. **Update the keybind tables** in `docs/REFERENCE.md` and `README.md` in the same commit.

Mirror the live config's path style: inline commands use `~/bin/...` (the tilde survives sync); absolute home paths get templated to `__HOME__`. Leader Key serializes as `"key" : "value"` with spaces around the colon, so make a surgical string edit instead of re-serializing, and the diff stays minimal. The fork owns its settings window: `⇪ l k` opens it through `msleaderkey://settings`.

## Shell and splash invariants (`shell/`)

Run this first after any shell change. Sourcing `aliases.zsh` in a normal pane must print nothing, randomized content included:

```zsh
out=$(env -u HOTKEY_PANE ITERM_PROFILE="Default" zsh -c 'source ~/projects/machine-spirit/shell/aliases.zsh' 2>&1) && [[ -z $out ]]
```

- Hotkey-window-only behavior gates on `ITERM_PROFILE == "Hotkey Window"`, an environment variable iTerm sets at launch. "Send text at start" runs too late; do not use it for environment variables.
- **Layout budget:** the whole splash fits the hotkey window (39 rows × 125 columns) with the prompt on the last row. Every element is width-guarded, and art taller than the budget drops the banner. After adding content, re-verify for every logo in `logos/`: no visible line wider than the window, total rows ≤ rows − 1.
- **Byte fidelity:** the typewriter emits ANSI escape sequences atomically. Any new animation keeps the final output identical: captured animated output equals unanimated output.
- **fastfetch logo files:** `$1` and `$9` are color placeholders, `$2` is the blink color, and a literal `$` is written `$$`.
- **iTerm profile settings live in iTerm's plist, which is not captured.** Whatever a subsystem needs from the profile (window size, blinking text, hotkey) is documented in [`docs/REFERENCE.md` → Terminal Splash & Wiring](docs/REFERENCE.md#terminal-splash--wiring) and applied by the user in Settings. Do not edit the plist while iTerm runs (it is overwritten on quit); `defaults write` for advanced keys such as `timeBetweenBlinks` is fine.
- The hotkey window adopts profile Rows/Columns only when it is recreated: close it fully, then re-summon, before debugging "my change didn't show".

## Disk and outputs

- Nothing generated is committed except the pre-rendered assets of invariant 4 and audited images in `docs/img/`. Captures, Pulse logs, clipboard content and scratch files stay outside the repo (`$TMPDIR`).
- Build products are ignored and safe to delete and rebuild: `.build/`, `DerivedData*/`. The hourly Pulse agent runs `tools/ms/.build/release/ms` from this checkout, so a release rebuild here is a deploy: check [`MANUAL-WIRING.md`](MANUAL-WIRING.md) step 15 afterward.
- Worktrees go beside the repo (`../ms-wt/<name>`, branch `wt/<name>`). Remove yours once the branch is merged and the tree is clean.
