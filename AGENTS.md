# AGENTS.md — Multi-Agent Engineering Contract

`machine-spirit` is co-authored by its human owner and multiple AI coding agents (**Claude**, **Codex**, and **Gemini**, alongside any future agent sessions). Every agent working on this repository shares this contract. Read it before modifying code, configs, or documentation.

> **Companion docs:**
> - [`VISION.md`](VISION.md) — design philosophy (*keyboard where keyboard wins, mouse where mouse wins*).
> - [`HANDOFF-NOTES.md`](HANDOFF-NOTES.md) — architectural decisions and forward-looking design cache.
> - [`MANUAL-WIRING.md`](MANUAL-WIRING.md) — consent gates and manual onboarding steps.
> - [`CHECKPOINTS.md`](CHECKPOINTS.md) — restore doctrine and checkpoint ledger.
> - [`docs/REFERENCE.md`](docs/REFERENCE.md) — exhaustive keybind, CLI, and wiring reference.
> - [`docs/VISUAL-AUDIT.md`](docs/VISUAL-AUDIT.md) — screenshot provenance and visible-text privacy audit.

---

## Core Invariants

1. **The repository is the canonical artifact.** Live configs (`~/Library/Application Support/Leader Key/config.json`, `~/.config/karabiner/karabiner.json`) are the source of truth for *content*; the repo is the source of truth for *existence*. Use [`scripts/sync.sh`](scripts/sync.sh) to pull live → repo, and [`install.sh`](install.sh) to replay repo → fresh Mac idempotently.
2. **Portable by construction.** Never commit a hard-coded username or `/Users/...` path. `sync.sh` templates `$HOME` to `__HOME__`, and `install.sh` expands it on restore.
3. **Public repository. Zero secrets. Always.**
   - Ensure hooks are active: `git config core.hooksPath .githooks`.
   - Every commit is scanned by `gitleaks` via [`.githooks/pre-commit`](.githooks/pre-commit).
   - Never capture full-desktop screenshots. Every image in `docs/img/` must be tightly cropped or rendered against a clean synthetic backdrop, stripped of EXIF/tEXt/iTXt/tIME metadata, visually inspected, and logged in [`docs/VISUAL-AUDIT.md`](docs/VISUAL-AUDIT.md).
4. **Runtime-light, pre-rendered assets.** Expensive art generation runs offline (see `shell/splash/banners/`); runtime dependencies stay minimal and declared in [`Brewfile`](Brewfile).
5. **Reduce window overflow.** Prefer one summonable, well-placed surface over unbounded stray windows.

---

## Docs & Visuals Drift Gate (Mandatory on Checkpoints)

Every `Checkpoint: ready` push automatically runs [`scripts/check-docs-drift.py`](scripts/check-docs-drift.py) via [`scripts/push-checkpoint.sh`](scripts/push-checkpoint.sh). It enforces:

1. **Keybind parity:** Every leaf shortcut in `config/leader-key/config.json` must be documented in [`docs/REFERENCE.md`](docs/REFERENCE.md) (and notable highlights reflected in [`README.md`](README.md)).
2. **Link & asset integrity:** Every Markdown link and image in `README.md` and `docs/REFERENCE.md` must resolve; every asset in `docs/img/` must appear in [`docs/VISUAL-AUDIT.md`](docs/VISUAL-AUDIT.md); PNGs must carry zero EXIF/text/time metadata chunks.
3. **UI-to-Visuals freshness:** Changes to visible UI surfaces (`CompactBar.swift`, `NowPlayingMenu.swift`, `StatusItem.swift`, `TypingOverlay.swift`, `GraphView.swift`, `AppsPane.swift`, `Clipboard*.swift`, `tools/ms/`, `shell/splash/`) must either refresh their corresponding docs/screenshots **or** include an explicit review trailer (`Visuals-Reviewed: current` / `Docs-Reviewed: current`) after verifying that existing visuals and copy are still accurate.

Run the evaluator locally before any checkpoint commit:

```bash
python3 scripts/check-docs-drift.py --range origin/main..HEAD --gate
```

---

## Multi-Agent Co-Authorship

This project is built collaboratively across models and harnesses. Never attribute the repository exclusively to a single agent or provider:

- Keep user-facing docs and contracts agent-agnostic (refer to agents generically or credit the full team: Claude, Codex, Gemini).
- On commits produced with AI assistance, use standard `Co-Authored-By:` trailers reflecting the participating agent(s).
- Keep [`CLAUDE.md`](CLAUDE.md) synced as the pointer/companion for Claude Code sessions.

---

## Checkpoint & Auto-Push Flow

In a configured clone (`git config core.hooksPath .githooks` and `git config machinespirit.pushCheckpoints true`):

- Ordinary commits on `main` stay local.
- A commit on `main` whose final trailer is `Checkpoint: ready` triggers [`.githooks/post-commit`](.githooks/post-commit) → [`scripts/push-checkpoint.sh`](scripts/push-checkpoint.sh), which verifies:
  1. Clean working tree and `git diff --check`
  2. `gitleaks` across all outgoing commits
  3. `scripts/check-docs-drift.py --range "$base..$head" --gate`
  4. `swift test` for `kit/MachineSpiritKit` and `tools/ms`
  5. `xcodebuild test` for `forks/LeaderKey` (when touched) and `xcodebuild build` for `app/MachineSpirit` (when touched)
  6. Fast-forward push to `origin/main`

## Subsystem Map & Shell Invariants

| Area | Path | Notes |
|---|---|---|
| Launcher & menu bar fork | `forks/LeaderKey/` | Owned Leader Key fork: key capture, hold mode, unified status bar, DDC brightness, Now Playing, clipboard panel |
| Overlay & board app | `app/MachineSpirit/` | Accessory app: Core Animation typing overlay, node-graph editor, embedded `sheol`, `Apps` pane |
| Shared Swift package | `kit/MachineSpiritKit/` | Node model, lossless importer/serializer, `ConfigWriter` write gate, radial layout |
| Native CLI & MCP server | `tools/ms/` | Zero-dependency Swift CLI + stdio MCP: windows, displays, binds, `sheol`, Pulse, OCR+Translate |
| Captured configs | `config/` | Leader Key (`__HOME__` templated), Karabiner, iTerm2 colors, tmux + launchd plists |
| Helpers | `bin/` | `web-jump`, `app-jump`, `app-toggle`, `win-lerp`, `sheol-core`, `tor-session.py`, `screenshots/` |
| Terminal & splash | `shell/` | `aliases.zsh` (silent in normal panes; gates on `ITERM_PROFILE == "Hotkey Window"`), pre-rendered banners |

Before committing shell changes, always verify silence in normal panes:

```zsh
out=$(env -u HOTKEY_PANE ITERM_PROFILE="Default" zsh -c 'source ~/projects/machine-spirit/shell/aliases.zsh' 2>&1) && [[ -z $out ]]
```
