# aesthetic-mac-setup

A reproducible, keyboard-driven macOS environment as version-controlled code. Clone it onto any Mac, run one script, and get the same launcher, key remaps, terminal, and window behavior back.

![showcase](docs/showcase_v2.png)

The philosophy is simple: the machine's configuration is a **canonical artifact**, not a pile of clicks you'll forget. Every change flows back into the repo, so the current state is always captured, diffable, and redeployable.

## Features

- **Leader-key launcher** ([Leader Key](https://github.com/mikker/LeaderKey)) — one activation key opens a nested, Vim-style shortcut tree. `⇪ c o` → Codex, `⇪ c l` → Claude, `⇪ i t` → iTerm, `⇪ g p` → ChatGPT app, `⇪ g w` → an existing ChatGPT tab in Safari, and so on. No global-shortcut collisions, no chords to memorize.
- **Silent leader key** ([Karabiner-Elements](https://karabiner-elements.pqrs.org/)) — Caps Lock is remapped to `F19`, a phantom key nothing else uses. It no longer capitalizes, the green LED never lights, and it becomes a clean, dedicated trigger.
- **Smart launch actions** — plain app launches focus-if-running / launch-if-closed automatically; the two that need more (Terminal window revival, ChatGPT tab de-duplication) are small AppleScripts in [`bin/`](bin/).
- **iTerm2** — terminal-first workflow, splits, and a custom color scheme. See [`config/iterm2/`](config/iterm2/).
- **Menu bar management** — Ice / Thaw to hide clutter behind a single toggle, with [Stats](https://github.com/exelban/stats) for system monitoring.
- **macOS tweaks** — snappier window resize and animation via reversible `defaults` writes.

## Quick start (fresh Mac)

```bash
git clone https://github.com/legions-dialect6s/aesthetic-mac-setup ~/aesthetic-mac-setup
cd ~/aesthetic-mac-setup
./install.sh
```

`install.sh` is idempotent. It installs Homebrew if missing, installs every app from the [`Brewfile`](Brewfile), restores your configs (backing up anything it replaces), and prints the short list of permissions macOS requires you to grant by hand.

## Keeping it in sync

The repo is **capture-based**: your live configs are the source of truth, and `sync.sh` pulls them in.

```bash
# after changing a keybind, remap, or script:
./scripts/sync.sh          # pull live config -> repo
git diff                   # review
git add -A && git commit -m "tweak: ..." && git push
```

Home-directory paths (e.g. inside Leader Key's config) are rewritten to a `__HOME__` placeholder on the way in and expanded back on install — so the repo is portable and never hard-codes a username.

## Security

This repo is meant to be **public**, so it is built to never leak secrets:

- A strict [`.gitignore`](.gitignore) blocks `.env`, keys, SSH/AWS/GPG dirs, shell histories, and other secret-bearing files.
- A [`gitleaks`](https://github.com/gitleaks/gitleaks) pre-commit hook scans staged changes and blocks the commit if a secret is detected. Enable it once:
  ```bash
  git config core.hooksPath .githooks
  ```
- Only ever commit **sanitized** copies of any shell config. If a file might hold a token, keep it out.

## Layout

```
aesthetic-mac-setup/
├── install.sh              # bootstrap a fresh Mac
├── Brewfile                # declarative app list
├── bin/                    # AppleScript helpers (chatgpt-web, terminal-front)
├── config/
│   ├── leader-key/         # captured Leader Key config (templated)
│   ├── karabiner/          # captured Karabiner config
│   └── iterm2/             # color scheme + notes
├── scripts/
│   ├── sync.sh             # live config -> repo
│   └── macos-defaults.sh   # reversible macOS tweaks
└── .githooks/pre-commit    # gitleaks secret scan
```

## License

MIT — see [LICENSE](LICENSE).
