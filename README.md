# machine-spirit

A reproducible, keyboard-driven macOS environment as version-controlled code. Clone it onto any Mac, run one script, and get the same launcher, key remaps, terminal, and window behavior back — including a terminal that greets you properly.

![terminal splash](docs/splash-showcase.png)


The philosophy is simple: the machine's configuration is a **canonical artifact**, not a pile of clicks you'll forget. Every change flows back into the repo, so the current state is always captured, diffable, and redeployable.

## Features

- **Leader-key launcher** ([Leader Key](https://github.com/mikker/LeaderKey)) — one activation key opens a nested, Vim-style shortcut tree. `⇪ c o` → Codex, `⇪ c l` → Claude, `⇪ i t` → iTerm, `⇪ g p` → ChatGPT app, `⇪ g w` → an existing ChatGPT tab in Safari, and so on. No global-shortcut collisions, no chords to memorize. Full listing in [Keybind reference](#keybind-reference).
- **Silent leader key** ([Karabiner-Elements](https://karabiner-elements.pqrs.org/)) — Caps Lock is remapped to `F19`, a phantom key nothing else uses. It no longer capitalizes, the green LED never lights, and it becomes a clean, dedicated trigger.
- **Smart launch actions** — plain app launches focus-if-running / launch-if-closed automatically; the two that need more (Terminal window revival, ChatGPT tab de-duplication) are small AppleScripts in [`bin/`](bin/).
- **Spatial window grid** ([Rectangle](https://rectangleapp.com/) driven from Leader Key via its URL scheme) — the window keys mirror screen positions: `⇪ q q q` top-left, `⇪ x x x` bottom half, `⇪ b b b` center third, and so on. Grow/shrink is a smooth eased animation from a small AppleScript, not an instant jump. See [Window management](#window-management).
- **iTerm2** — terminal-first workflow, splits, and a custom color scheme. See [`config/iterm2/`](config/iterm2/).
- **Hotkey-window splash** ([`shell/splash/`](shell/splash/)) — every summon of the hotkey terminal boots a randomized, typed-out splash: blackletter banners in five scripts, an ASCII skull or dragon, fastfetch, a quote from a 54-deep rotation, and blinking unicode charms. See [Terminal splash](#terminal-splash) below.
- **Menu bar management** — Ice / Thaw to hide clutter behind a single toggle, with [Stats](https://github.com/exelban/stats) for system monitoring.
- **macOS tweaks** — snappier window resize and animation via reversible `defaults` writes.

## Quick start (fresh Mac)

```bash
git clone https://github.com/legions-dialect6s/machine-spirit ~/machine-spirit
cd ~/machine-spirit
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

## Keybind reference

**How to run anything:** tap `⇪` (Caps Lock — remapped to F19, so it never capitalizes), then type a sequence. Leader Key pops a panel showing the keys available at each level, so you can explore by just tapping `⇪` and looking. `Esc` backs out. `⇪ l k` opens Leader Key's own settings.

The tree follows four rules, by escalating "weight" of the action:

1. **One tap** — frequent and harmless: `h` hides, `y` cycles YouTube tabs.
2. **Two taps, first-two-letters mnemonic** — apps and tools: `m e` → **Me**ssages, `s p` → **Sp**otify, `d i` → **Di**scord. Read the sequence as the start of the app's name.
3. **Three taps of the same letter** — window placement. The repetition is deliberate friction (a mistyped sequence never yeets a window) and the letters form a spatial grid (see [Window management](#window-management)). The two exceptions are grow/shrink at two taps, because they're pressed repeatedly.
4. **Spelled-out words** — destructive actions: `q u i t` literally types the word to ⌘Q the frontmost app. Quitting should never be one slip away; making you spell it *is* the confirmation dialog.

### Apps

| Keys | Opens | | Keys | Opens |
|---|---|---|---|---|
| `⇪ a c` | Activity Monitor | | `⇪ p h` | Photos |
| `⇪ c l` | Claude | | `⇪ p s` | Photoshop |
| `⇪ c o` | Codex | | `⇪ s a` | Safari |
| `⇪ d i` | Discord | | `⇪ s e` | System Settings |
| `⇪ f a` | FaceTime | | `⇪ s p` | Spotify |
| `⇪ f i` | Finder | | `⇪ t e` | TextEdit |
| `⇪ g p` | ChatGPT | | `⇪ t r` | Terminal |
| `⇪ i t` | iTerm | | `⇪ w h` | WhatsApp |
| `⇪ m e` | Messages | | `⇪ n o` | Notes |

### Web (jump to an existing tab instead of opening a duplicate)

| Keys | Goes to | Notes |
|---|---|---|
| `⇪ g i t` | GitHub | spells "git" |
| `⇪ g o` | Google | finds an existing tab or opens one |
| `⇪ g w` | ChatGPT web | tab de-dupe via [`bin/chatgpt-web.applescript`](bin/) |
| `⇪ i g` | Instagram | |
| `⇪ s x` | X | |
| `⇪ r r` | personal site | |
| `⇪ y` | YouTube | cycles through YouTube tabs |

### Folders & terminal

| Keys | Action |
|---|---|
| `⇪ f d` | Downloads |
| `⇪ f p` | ~/projects |
| `⇪ f s s` | screenshots folder |
| `⇪ i n` | new iTerm window |

### Screenshots (`⇪ s s …` — screen, then how)

| Keys | Action |
|---|---|
| `⇪ s s s c` / `⇪ s s s s` | **s**election → **c**opy / **s**ave |
| `⇪ s s w c` / `⇪ s s w s` | **w**hole screen → **c**opy / **s**ave |
| `⇪ s s r s` / `⇪ s s r w` | **r**ecord **s**election / **w**hole screen |
| `⇪ s s r x` | stop recording |
| `⇪ s s f` / `⇪ s s m` | reveal in Finder / screenshot menu |

### System

| Keys | Action |
|---|---|
| `⇪ h` | hide frontmost app (⌘H) |
| `⇪ q u i t` | quit frontmost app (⌘Q) — spelled out on purpose |
| `⇪ l k` | Leader Key settings |

Window placement and resize live in [Window management](#window-management) below. This listing is maintained by hand — after changing bindings, re-run `./scripts/sync.sh` and update the tables in the same commit.

## Window management

Rectangle does the window math; Leader Key drives it through Rectangle's URL scheme (`open -g "rectangle://execute-action?name=..."`). The bindings form a spatial grid — each key sits on the keyboard where it sends the window on screen:

```
⇪ q q q   top-left        ⇪ w w w   top half        ⇪ e e e   top-right
⇪ a a a   left half                                 ⇪ d d d   right half
⇪ z z z   bottom-left     ⇪ x x x   bottom half     ⇪ c c c   bottom-right
⇪ v v v   left third      ⇪ b b b   center third    ⇪ n n n   right third
⇪ c s s   center          ⇪ m m m   maximize        ⇪ f f f   other display
⇪ = =     grow            ⇪ - -     shrink          ⇪ q u i t  ⌘Q frontmost app
```

- **Triple letters** for placement so a fat-fingered leader sequence never yeets a window; the two resize keys are **double-taps** because they're pressed repeatedly. (Notes moved to `⇪ n o` when `n` became the right-third group.)
- **Grow/shrink bypass Rectangle**: [`bin/win-lerp.applescript`](bin/win-lerp.applescript) animates the frontmost window ±120 px over 22 smoothstep-eased frames — centered as it scales, clamped at screen edges, with a 300×200 floor so shrink-spam can't crush a window. Rectangle's resizes are instant jumps; this one glides.
- **`⇪ f f f`** cycles displays (with two monitors, a toggle); Rectangle centers the window on arrival, so no follow-up action is needed.
- Rectangle's *native* larger/smaller step is bumped to 100 px by [`scripts/macos-defaults.sh`](scripts/macos-defaults.sh) for when it's triggered outside Leader Key.

## Terminal splash

![terminal splash](docs/splash-showcase.png)

Every summon of the iTerm hotkey window boots a randomized splash, typed to the screen a character at a time (`shell/splash/splash.zsh`):

- **Banner** — "welcome user" pre-rendered in blackletter and engraved typefaces × four languages (English, Finnish, Swedish, Old English), stepped through one per launch, plus Arabic calligraphy and Paleo-Hebrew one-offs. 38 banners in [`shell/splash/banners/`](shell/splash/banners/) — delete all but your favorites to lock in.
- **Caption** — blinking `+++ 𝖂𝖊𝖑𝖈𝖔𝖒𝖊 𝖀𝖘𝖊𝖗 +++` in blackletter unicode, following the banner's language.
- **Logo** — random pick from [`shell/splash/logos/`](shell/splash/logos/) (winged censer skull, dragon). Art too tall for the window automatically drops the banner for that launch. Add your own: any ASCII art as a `.txt` (`$1`/`$2` are fastfetch color placeholders, `$2` blinks; escape literal `$` as `$$`).
- **System info** — fastfetch beside the logo; the separator line is a rhythm of cuneiform `𒐫`, re-randomized every launch.
- **Quote** — one of ~54: Heraclitus and Plotinus in Greek with translation, Quran in Arabic and English, KJV/Geneva apocalyptica, Old Norse Hávamál, Nietzsche in German, Nick Land, Planescape: Torment. One `text|Source` line each in [`shell/splash/quotes.txt`](shell/splash/quotes.txt) — add anything.
- **Charms** — up to three random ornaments (`⛧ ⛥ ⛧`, `𓂀 ☥ 𓂀`, `ᛉ ᛟ ᛉ`, ...) beside short info lines, width-guarded so they never wrap. They type in dim, then flicker in to a static bright once the splash settles.

### Wiring

- Sourced from `shell/aliases.zsh`; fires only when `ITERM_PROFILE` is `Hotkey Window` (or `HOTKEY_PANE=1` for testing). Normal panes stay completely silent.
- Runtime dependencies: zsh, iTerm2, and `fastfetch` (in the Brewfile). All art ships pre-rendered.
- iTerm profile expectations: a hotkey-window profile named **Hotkey Window**, roughly 39 rows × 125 columns, **Blinking text** enabled. `touch ~/.hushlogin` reclaims the "Last login" row; slow the blink with `defaults write com.googlecode.iterm2 timeBetweenBlinks -float 1.2`. iTerm only applies profile Rows/Columns when the hotkey window is recreated.
- The `𒐫` separator and Paleo-Hebrew caption need a font with those glyphs (Noto Sans Cuneiform / Phoenician) — everything else is self-contained.
- Knobs: `HOTKEY_SPLASH_BURST` (typing speed), `HOTKEY_SPLASH_CAPTION`, `HOTKEY_SPLASH_LOGO`, `HOTKEY_SPLASH_ORNAMENTS=0`.
- Regenerating art: [`shell/splash/tools/`](shell/splash/tools/) has the CoreText text→PNG renderers and the density-based ASCII downsampler; banners came from OFL typefaces (Google Fonts) via `chafa --symbols block --stretch -s 114x10`.

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
machine-spirit/
├── install.sh              # bootstrap a fresh Mac
├── Brewfile                # declarative app list
├── CLAUDE.md               # handoff: teaches agent sessions this repo's rules
├── bin/                    # AppleScript helpers (chatgpt-web, terminal-front, win-lerp)
├── config/
│   ├── leader-key/         # captured Leader Key config (templated)
│   ├── karabiner/          # captured Karabiner config
│   └── iterm2/             # color scheme + notes
├── shell/
│   ├── aliases.zsh         # sourced from ~/.zshrc; gates the splash
│   ├── cc-image-watch.sh   # live inline-image feed for Claude Code panes
│   └── splash/             # hotkey-window boot splash
│       ├── splash.zsh      # engine: typewriter, rotation, charms
│       ├── banners/        # pre-rendered "welcome user" wordmarks
│       ├── logos/          # ASCII art pool (skull, dragon, yours)
│       ├── quotes.txt      # one text|Source per line
│       └── tools/          # art pipeline: text->PNG, ASCII downsampler
├── scripts/
│   ├── sync.sh             # live config -> repo
│   └── macos-defaults.sh   # reversible macOS tweaks
└── .githooks/pre-commit    # gitleaks secret scan
```

## License

MIT — see [LICENSE](LICENSE).


![showcase](docs/showcase_v2.png)
