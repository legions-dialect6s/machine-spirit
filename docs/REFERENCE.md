# machine-spirit — Complete Reference Manual

This document is the exhaustive keybind table, architecture specification, wiring guide, and operational manual for **machine-spirit**. For the narrative overview and visual showcase, see [`README.md`](../README.md).

> Every leaf keybind in [`config/leader-key/config.json`](../config/leader-key/config.json) is checked against this file by [`scripts/check-docs-drift.py`](../scripts/check-docs-drift.py) on every `Checkpoint: ready` push.

---

## Contents

- [Keybind Grammar & Reference](#keybind-grammar--reference)
  - [Apps](#apps) · [Web Jumps](#web-jumps) · [Folders & Terminal](#folders--terminal)
  - [Screenshots](#screenshots) · [System & Utilities](#system--utilities) · [tmux & Sheol](#tmux--sheol)
  - [Window Management & Multi-Display Grid](#window-management--multi-display-grid) · [Hold Mode](#hold-mode)
- [Launcher Fork & Menu Bar Internals](#launcher-fork--menu-bar-internals)
- [Clipboard History](#clipboard-history)
- [MachineSpirit.app — Board, Overlay & Apps Pane](#machinespiritapp--board-overlay--apps-pane)
- [Terminal Splash & Wiring](#terminal-splash--wiring)
- [tmux Protection, Sheol & Snapshots](#tmux-protection-sheol--snapshots)
- [`ms` CLI, MCP Server & Pulse Telemetry](#ms-cli-mcp-server--pulse-telemetry)
- [Busy-Pane Shield (Opt-In)](#busy-pane-shield-opt-in)
- [Command Reliability & Privacy](#command-reliability--privacy)
- [Sync, Checkpoints & Docs Drift Gate](#sync-checkpoints--docs-drift-gate)
- [Repository Layout](#repository-layout)

---

## Keybind Grammar & Reference

Tap **`⇪`** (Caps Lock, remapped to **F19** by Karabiner-Elements so it never capitalizes or lights the Caps Lock LED), then type a sequence:

1. **One tap** — high-frequency, harmless jumps (`⇪ y` → YouTube, `⇪ k` → Clipboard history).
2. **Two taps (first-two-letters mnemonic)** — apps and sites (`⇪ s p` → **Sp**otify, `⇪ m e` → **Me**ssages, `⇪ g m` → **Gm**ail).
3. **Three repeated taps** — spatial window placement (`⇪ q q q` → top-left, `⇪ d d d` → right half). Deliberate friction prevents accidental moves; grow/shrink (`⇪ = =`, `⇪ - -`) use two taps because they repeat.
4. **Spelled-out words** — high-consequence or system actions (`⇪ q u i t`, `⇪ s l e e p`, `⇪ h i d e`, `⇪ s h o w`, `⇪ c a p s`, `⇪ t m u x`, `⇪ m a c h i n e s p i r i t`).

Press `⌫` to step back one level (at the root skull, type another route immediately without pressing Caps again), `Esc` to dismiss, or **`⇪ Esc`** at the root to blur/un-capture the frontmost text field. Keep holding `⇪` after a bind fires to stay in [Hold Mode](#hold-mode).

### Apps

**✕** marks toggleable utilities handled by [`bin/app-toggle.applescript`](../bin/app-toggle.applescript): the first invocation opens or focuses the app; repeating it while focused closes/quits it cleanly (TextEdit prompts on unsaved edits; Little Snitch closes its monitor windows).

| Keys | Action | Keys | Action |
|---|---|---|---|
| `⇪ a c` | Activity Monitor | `⇪ m a i l` | Mail ✕ |
| `⇪ b l e` | Blender | `⇪ m e` | Messages → conversation search (`messages-find.sh`) |
| `⇪ c a l` | Calendar ✕ | `⇪ n o` | Notes ✕ |
| `⇪ c h r` | Google Chrome (jump/cycle) | `⇪ p b` | Photo Booth ✕ |
| `⇪ c l` | Claude | `⇪ p h` | Photos ✕ |
| `⇪ c o` | Codex (`/Applications/ChatGPT.app`) | `⇪ p s` | Adobe Photoshop (hold `s`: next document) |
| `⇪ c x` | Contacts ✕ | `⇪ p w` | Apple Passwords |
| `⇪ d i` | Discord | `⇪ s a` | Safari (jump/cycle; hold `a`: merge windows) |
| `⇪ f a c` | FaceTime ✕ | `⇪ s e` | System Settings ✕ |
| `⇪ f c 2` | Focusrite Control 2 | `⇪ s i g` | Signal (jump/cycle) |
| `⇪ f i` | Finder (jump/cycle; hold `i`: gather tabs) | `⇪ s p` | Spotify |
| `⇪ f m` | Find My ✕ | `⇪ t 3` | T3 Code |
| `⇪ f t` | FaceTime ✕ (from Messages: call selected chat) | `⇪ t e l` / `⇪ t g` | Telegram |
| `⇪ g p` | ChatGPT Classic | `⇪ t e r` | Terminal |
| `⇪ i t` | iTerm (focus/raise frontmost) | `⇪ t e x` | TextEdit ✕ (closes all; asks if unsaved) |
| `⇪ l s l s` | Little Snitch | `⇪ t o r` | Tor Browser (isolated ARM64 Linux kiosk VM via `tor-session.py`) |
| `⇪ l s n m` | Little Snitch Network Monitor ✕ | `⇪ u r` | Unreal Editor (cycle windows; hold `r`) |
| `⇪ v l c` | VLC (jump/cycle) | `⇪ v m w` | VMware Fusion (`vmware.applescript`) |
| `⇪ w h` | WhatsApp | `⇪ x c` | Xcode |

`⇪ s a`, `⇪ c h r`, `⇪ f i`, `⇪ s i g`, and `⇪ v l c` share [`bin/app-jump.applescript`](../bin/app-jump.applescript): not running → launch; backgrounded → restore minimized windows and bring forward; already frontmost → cycle windows in order via native `⌘\`` / `⌘N`.

### Web Jumps

All web binds run [`bin/web-jump.applescript`](../bin/web-jump.applescript) + [`bin/web-browser.js`](../bin/web-browser.js): focus an existing matching tab, cycle across matches, or open the fallback URL. Set `MS_BROWSER_BUNDLE_ID` in the launcher environment to target a specific browser. In Safari, keep `⇪` held and tap the final key again to gather matching tabs into one window ([`bin/web-collect.sh`](../bin/web-collect.sh)).

| Keys | Site / Action | Domains / Notes |
|---|---|---|
| `⇪ d r` | Google Drive | `drive.google.com` |
| `⇪ g i t` | GitHub | `github.com` |
| `⇪ g m` | Gmail | `mail.google.com` |
| `⇪ g o` | Google | `google.com` |
| `⇪ g r o k` | Grok | `grok.com`, `x.com/i/grok` |
| `⇪ g w` | ChatGPT Web | `chatgpt.com`, `chat.openai.com` |
| `⇪ i g` | Instagram | `instagram.com` |
| `⇪ s h o p` | Shopify Admin | `admin.shopify.com` |
| `⇪ s t` / `⇪ s x` / `⇪ x .` | X / Twitter | `x.com`, `twitter.com` |
| `⇪ t r i` | Tripo 3D | `tripo3d.ai` |
| `⇪ y` | YouTube | `youtube.com` |
| `⇪ r r` | Strip current tab URL to site home | [`bin/site-home.applescript`](../bin/site-home.applescript) |

### Folders & Terminal

| Keys | Opens |
|---|---|
| `⇪ f a e` | Aesthetics folder (`~/Desktop/aesthetics`) |
| `⇪ f a p p` | `/Applications` |
| `⇪ f d o c` | `~/Documents` |
| `⇪ f d o w` | `~/Downloads` |
| `⇪ f p` | `~/projects` |
| `⇪ f s s` | `~/Documents/screenshots_n_recordings` |
| `⇪ f . . . . .` | Trash in Finder |
| `⇪ i n` | New iTerm window |

### Screenshots

Under `⇪ s s …` (*screen, then how*; routed through [`bin/run-quiet.sh`](../bin/run-quiet.sh) so pressing `Esc` to cancel never raises a modal error alert). At `s s s`, the overlay highlights the pending screenshot cue in amber.

| Keys | Action |
|---|---|
| `⇪ s s s c` / `⇪ s s s s` | Selection → copy / save |
| `⇪ s s w c` / `⇪ s s w s` | Whole screen → copy / save |
| `⇪ s s r s` / `⇪ s s r w` | Record selection / whole screen |
| `⇪ s s r x` | Stop active screen recording |
| `⇪ s s f` / `⇪ s s m` | Reveal screenshots folder / open macOS screenshot menu |

### System & Utilities

| Keys | Action |
|---|---|
| `⇪ k` | Native Clipboard history panel (`msleaderkey://clipboard`, also `⌘⇧V`) |
| `⇪ c b h` | Legacy clipboard shortcut macro (sends `⌘⇧V` via System Events) |
| `⇪ c a p s` | Toggle real hardware Caps Lock (`ms capslock toggle`) + glass pointer pill |
| `⇪ e t` / `⇪ t r a` | Drag screen area → on-device Vision OCR + Translation → clipboard + HUD |
| `⇪ a u` | Tile windows of all apps currently playing audio (`ms audio tile`) |
| `⇪ h h` | Hide frontmost app (`⌘H`) |
| `⇪ h i d e` | Hide all apps (`ms win hide-all`) |
| `⇪ s h o w` | Unhide, un-minimize, and tile all windows across displays (`ms win tile-all`) |
| `⇪ l l` | Focus primary address/search bar (`⌘L` in frontmost app) |
| `⇪ l k` | Open Leader Key fork settings (`msleaderkey://settings`) |
| `⇪ m a c h i n e s p i r i t` | Open transient MachineSpirit board (`machinespirit://board?transient=1`) |
| `⇪ q u i t` | Quit frontmost app (`⌘Q`) — intentionally spelled out |
| `⇪ s l e e p` | Sleep display only (`sleep 2 && pmset displaysleepnow`, backgrounded so key-up settles) |

### tmux & Sheol

| Keys | Action |
|---|---|
| `⇪ t t` | Launch a new tmux-protected iTerm window (`tmux-launch.sh` → `tmux-session.sh`) |
| `⇪ t d` | Split current iTerm pane into a tmux-protected shell (`tmux-split.sh`) |
| `⇪ t m u x` | Open **sheol**, the single-instance tmux ledger (`tmux-sheol-open.sh`); hold `x` to spawn & spiral panes |
| `⇪ t q q q q` | Kill active tmux pane in frontmost iTerm window (four-tap `◆◆◆◆` ward; safe no-op if non-tmux) |

### Window Management & Multi-Display Grid

Machine Spirit handles half-steps, mouse-aim placement, fullscreen bounce, maximize/almost-maximize, and display transfers natively via [`ms win`](../tools/ms/README.md); other grid positions dispatch to Rectangle via `ms win rectangle`.

| Keys | Action | Keys | Action |
|---|---|---|---|
| `⇪ q q q` | Top-left quarter | `⇪ w w w` | Step up by half-screen (crosses vertically aligned displays) |
| `⇪ e e e` | Top-right quarter | `⇪ a a a` | Left half |
| `⇪ d d d` | Right half | `⇪ z z z` | Bottom-left quarter |
| `⇪ x x x` | Step down by half-screen (crosses displays) | `⇪ c c c` | Bottom-right quarter |
| `⇪ v v v` / `⇪ 1 1 1` | Left / first third | `⇪ b b b` / `⇪ 2 2 2` | Center third |
| `⇪ n n n` / `⇪ 3 3 3` | Right / last third | `⇪ c s s` | Center (Rectangle) |
| `⇪ c e n` | Center on current display (`center-window.applescript`) | `⇪ m m m` | Maximize (exact usable frame above Dock) |
| `⇪ a m m m` | Almost-maximize (90% inset) | `⇪ ␣ ␣` | Place by mouse (corner → quarter, edge → half, center → 90%/max; repeat to ladder) |
| `⇪ ␣ m` | Toggle native fullscreen (`ms win place toggle-fullscreen`) | `⇪ = =` / `⇪ - -` | Smoothstep grow / shrink ±120 px (`win-lerp.applescript`) |
| `⇪ f f f` / `⇪ g g g` | Next / previous display (hold `f`/`g` to keep stepping) | `⇪ ← ←` / `⇪ → →` / `⇪ ↑ ↑` / `⇪ ↓ ↓` | Move window to display left / right / above / below |

**Destination previews:** On the first letter of a triple-letter chord, the overlay outlines the target window with an animated dashed stroke; the second letter draws a solid green destination frame (or names both displays before a monitor transfer); the third commits and tracks the landed bounds. A red outlined callout explains missing destinations; `Esc` clears pending previews.

### Hold Mode

If `⇪` stays physically held when a bind fires, the fork's event tap keeps listening without stealing focus from the target app until you release `⇪`:

- Binds with `"hold"` / `"holdKeys"` re-run with `MS_HOLD_N` (`1, 2, 3…`) and `MS_HOLD_KEY`. Exit `10` pulses the overlay blue ("done"); exit `11` flashes red ("nothing to do").
- `␣` after **any** bind places the frontmost window at the mouse and walks the grow ladder (through native fullscreen).
- Any other key starts a fresh sequence from the root while still holding `⇪`.

| After | Repeat while holding `⇪` | Behavior |
|---|---|---|
| Any web jump | Its final key | Collect matching Safari tabs into one window, then cycle |
| `⇪ s a` | `a` | Invoke Safari **Window → Merge All Windows** |
| `⇪ f i` | `i` | Gather Finder windows into tabs (pulses blue when none remain) |
| `⇪ t m u x` | `x` | Spawn protected tmux window, then spiral splits (maximizes at 3, tiles at 5+) |
| `⇪ p s` / `⇪ u r` | `s` / `r` | Cycle Photoshop documents / Unreal Editor windows |
| `⇪ f f f` / `⇪ g g g` | `f` / `g` | Continue moving across displays in the initial direction |

---

## Launcher Fork & Menu Bar Internals

**MachineSpirit Leader Key** ([`forks/LeaderKey`](../forks/LeaderKey), MIT fork of `mikker/LeaderKey`) runs from `~/Applications/MachineSpirit Leader Key.app` (`com.machinespirit.leader-key`), signed with the per-machine **MachineSpirit Local Codesign** certificate and kept alive on crash by [`config/leader-key/com.machinespirit.leader-key.plist`](../config/leader-key/com.machinespirit.leader-key.plist) (`SuccessfulExit=false` respects clean Quit).

- **Config watching:** `ConfigFileMonitor` watches `~/Library/Application Support/Leader Key/config.json` with a **300 ms debounce** and re-arms after atomic rename swaps.
- **Compact status bar (`CompactBar.swift` & `SystemStats.swift`):**
  - Fixed-width columns separated by subtle vertical group dividers (`|`): **Skull** · **T3** (`working/open` top-level unsettled tasks from the local v2 SQLite registry, refreshed off-main every ≤4 s) · **CPU / GPU / RAM / MPRS** (kernel memory pressure `1/3`, `2/3`, `3/3`, mint/amber/red) **TEMP** · **Disks** (`SSD1`, `SSD2`, `HDD1`, etc., classified via DiskArbitration + IOKit, excluding virtual disk images, updated immediately on mount/unmount/rename) · **TM** (Time Machine backup volumes separated by their own divider) · upright **Keep-Awake molecule**.
  - One shared **2-second timer (0.5 s tolerance)** drives closed-menu updates with **zero subprocesses**. Detailed 1-second stats and `ps` top-process sampling run *only while the menu is open*.
- **Now Playing (`NowPlayingMenu.swift`):** Appears directly below Brightness in the main menu. CoreAudio process taps run only while the menu is open. Audible browser tabs in Safari and Chromium-family browsers resolve clean page titles, host-only favicons, and click-to-focus (raising the exact window and selecting the audible tab).
- **Brightness & DDC/CI (`BrightnessController.swift` & `DisplayHardware.swift`):** Built-in displays use `DisplayServices`; external displays use DDC/CI over `IOAVService` with one serial queue per display and trailing-edge coalescing. Slider **25–100** maps to hardware brightness **0–100%** (1% built-in backlight floor); **0–25** extends below hardware minimum using **15–100% gamma**, restoring ColorSync cleanly on leave or quit. Brightness keys step **6.25%** across all displays when Sync is on (`msBrightnessSync`).
- **Keep Awake:** Off, Indefinitely, 15m, 1/2/4/8h; persists active assertions and timed deadlines across restarts; **Keep display on too** defaults on.
- **Terminals & tmux menu:** Shows the 8 most recently active sessions at top level (rest in **More…**) with revive, detach, triple-tap `◆◆◇` close wards, and live AI-agent process markers (Claude, Codex, Grok, Gemini, DeepSeek, Kimi, Qwen, Aider, OpenCode, Goose, Cursor).

---

## Clipboard History

Triggered by **`⌘⇧V`**, **`⇪ k`**, or **Menu bar → Clipboard history…** (`msleaderkey://clipboard`). Opens a native dark AppKit panel anchored at the pointer within the current display.

- **Controls:** Substring/fuzzy search, `↑`/`↓` select, `Return` paste into previous app, `⌥Return` copy only, `⌘1`–`⌘9` quick pick, `⌘P` pin/unpin, `⌫` delete (when search empty), `Esc` close.
- **Storage & limits:** Owner-only directory `~/Library/Application Support/MachineSpirit/clipboard/` (`index.json` + PNGs). Keeps **300 entries** (up to **50 images**, resized ≤2048 px per side); pins never evict. Caps individual payloads (text >8 MiB, RTF >16 MiB, images >64 MiB). Ignores concealed, transient, autogenerated, 1Password-marked, and self-originated pasteboard writes. Note: ordinary copied text without a sensitive marker is stored locally unencrypted.

---

## MachineSpirit.app — Board, Overlay & Apps Pane

Installed at `~/Applications/MachineSpirit.app` via [`./app/MachineSpirit/tools/deploy-release.sh`](../app/MachineSpirit/tools/deploy-release.sh) (launched in the background by the Leader Key fork unless `msLaunchBoardAtLogin` is false — do not add a duplicate Login Item).

- **Typing Overlay (`TypingOverlay.swift`):** Prebuilt persistent `CALayer` tree (**166 nodes / 1,331 layers** in the measured config), click-through, anchored to the initial pointer position, fanning inward near screen edges. Warm focus commit median **0.618 ms**; settled idle **0.0% CPU** ([verification report](../app/MachineSpirit/Tests/OverlayV3Verification.md)). Driven via `com.machinespirit.leader.{nav,fired,feedback,placement,placement.miss,window.focus}` distributed notifications. Optional shortcut audio/speech in **Graphics & feedback** (off by default).
- **Node-Graph Board:** Interactive Canvas with walk-by-key, drag-and-drop node arrangement, non-destructive `radial ⇄ hand` named layouts, embedded `sheol` terminal pane, opt-in local shortcut stats (`msStatsEnabled`, daily counts + paths only), and **+ / −** live config editing guarded by `ConfigWriter` (round-trip check → timestamped backup → temp-write + re-import validation → atomic rename).
- **Apps Pane (`AppsPane.swift` & `machinespirit://apps`):** The first T-O-R launch opens connection setup. VPN + Tor requires an imported, owner-only WireGuard configuration and keeps the guest kill switch mandatory. Tor-only sessions require an explicit confirmation on every launch. The native Mac window shows VPN connecting, a recent handshake, or traffic blocked. Connection status uses handshake age, with a three-second check and a 180-second freshness limit. The Mac app uses absolute pointer coordinates and maps common Command browser shortcuts to guest Control shortcuts. Imported keys remain on the Mac until removed. Browser rendering and the session clipboard remain inside Linux.

---

## Terminal Splash & Wiring

Sourced from [`shell/aliases.zsh`](../shell/aliases.zsh); executes **only** when `ITERM_PROFILE == "Hotkey Window"` (or `HOTKEY_PANE=1`). Normal panes emit zero output.

- **Assets:** 38 offline pre-rendered multilingual blackletter/engraved banners in [`shell/splash/banners/`](../shell/splash/banners/), ASCII art in [`shell/splash/logos/`](../shell/splash/logos/), curated quotes in [`shell/splash/quotes.txt`](../shell/splash/quotes.txt), and fastfetch telemetry separated by randomized cuneiform `𒐫`.
- **iTerm profile expectations:** Profile named **Hotkey Window**, ~39 rows × 125 columns, **Blinking text** enabled (`defaults write com.googlecode.iterm2 timeBetweenBlinks -float 1.2`, `touch ~/.hushlogin`). Recreate the hotkey window after changing Rows/Columns.
- **Knobs:** `HOTKEY_SPLASH_BURST`, `HOTKEY_SPLASH_CAPTION`, `HOTKEY_SPLASH_LOGO`, `HOTKEY_SPLASH_ORNAMENTS=0`.
- **Inline image feed:** [`shell/cc-image-watch.sh`](../shell/cc-image-watch.sh) streams generated images inline inside iTerm2.

---

## tmux Protection, Sheol & Snapshots

- **`bin/sheol-core`** provides shared policy-free primitives (`list`, `list --json`, `revive`, `detach`, `kill`, `save`, `restore`, `kill-all`) consumed by the TUI, menu bar, board, and `ms` CLI.
- **`bin/tmux-sheol.sh`** (bash 3.2 safe, alternate screen, ~2 s live refresh) splits sessions into **☀ THE LIVING** (attached) and **⌁ SHEOL** (detached):
  - `↑`/`↓` or `j`/`k` navigate · `r` revive in new iTerm window · `c` commune in place (`Ctrl-b d` returns) · `d d d` two-tier banish (detach living / exile detached) · `s` save snapshot · `R` restore snapshot · `q` ×10 on `☠ BANISH ALL` saves then kills server · `n` spawn new protected session.
- **Snapshots:** [`config/tmux/tmux.conf`](../config/tmux/tmux.conf) wires `tmux-resurrect` + `tmux-continuum` (pinned SHAs, no plugin manager). [`com.machinespirit.tmux-autosave.plist`](../config/tmux/com.machinespirit.tmux-autosave.plist) saves every **15 minutes** via `launchd` (synchronous, no-op when empty; `@continuum-restore off` prevents surprise boot restores). Snapshots reconstruct layouts, scrollback, and supported commands — not running process memory.
- **Idle cleanup:** `terminals-core reap` quietly closes idle non-tmux login shells (≥3 min untouched, never the hotkey window), rate-limited to once per minute.

---

## `ms` CLI, MCP Server & Pulse Telemetry

Zero-dependency Swift 6 package under [`tools/ms/`](../tools/ms/) (macOS 14+). Build once with `swift build -c release --package-path tools/ms`, then run via `./bin/ms` (symlinked to `~/bin/ms` by `install.sh`).

```bash
./bin/ms screens --json
./bin/ms windows --app Safari --json
./bin/ms binds --tree --grep screenshot
./bin/ms run s/s/s/c --dry-run --json
./bin/ms tmux list --json
./bin/ms stats --json
./bin/ms capslock status
./bin/ms audio list
./bin/ms pulse report --hours 24
./bin/ms pulse disk --crash-preview
./bin/ms pulse disk --explain
```

- **MCP server:** `ms mcp` speaks stdio JSON-RPC for AI agents, exposing screens, windows, focus, binds, configured action execution (`run`), `tmux` list/revive/detach (never kill/save/restore), `stats`, `audio_list`, `pulse_report`, `pulse_disk`, and scoped screenshots. Clipboard history reads are disabled unless `MS_ALLOW_CLIPBOARD=1`.
- **Pulse telemetry:** Hourly LaunchAgent (`MS_INSTALL_PULSE=1` on fresh install; unload with `launchctl bootout "gui/$(id -u)/com.machinespirit.pulse"`) appends private monthly JSONL snapshots under `~/Library/Application Support/MachineSpirit/pulse/` (app/window counts, resources, duplicate-tab counts, up to 10 hostnames/browser, optional external-drive tracking, and idle reviews after 10 min inactivity). Nothing leaves the Mac. See [`tools/ms/README.md`](../tools/ms/README.md) for full schemas and flags.
- **Blur focused editor (`⌘ Esc`):** Moves focus out of editable fields via Accessibility (configurable in General settings); [`bin/messages-find.sh`](../bin/messages-find.sh) handles Messages search focus.

---

## Busy-Pane Shield (Opt-In)

Default **off**. An iTerm2 Python-API daemon ([`bin/pane-shield.py`](../bin/pane-shield.py)) that gives busy terminal panes a Halo-style escalating shield on `⌘W` before closing on the 4th hit. Toggle instantly with `~/bin/shield-on.sh` and `~/bin/shield-off.sh`.

---

## Command Reliability & Privacy

- **Zero focus-stealing error dialogs:** Standalone AppleScripts wrap bodies in `try … on error … end try`; shell commands route through [`bin/run-quiet.sh`](../bin/run-quiet.sh) (always `exit 0`); the fork's command runner executes off the main thread with a bounded 64 KiB pipe buffer.
- **Data disclosure:** Local opt-in shortcut stats (`stats.json`), local Pulse snapshots (`pulse/`), local clipboard archive (`clipboard/`), and local T3 SQLite task queries all stay strictly on the Mac. Website shortcut icons and Now Playing browser-tab favicons query Google's `/s2/favicons` service with the public hostname only.
- **Security:** Strict [`.gitignore`](../.gitignore), `gitleaks` pre-commit hook (`.githooks/pre-commit`), `__HOME__` path templating in `sync.sh`, and mandatory visual audits in [`docs/VISUAL-AUDIT.md`](VISUAL-AUDIT.md).

---

## Sync, Checkpoints & Docs Drift Gate

```bash
# 1. Capture live config edits into the repo
./scripts/sync.sh

# 2. Check docs & visuals freshness locally
python3 scripts/check-docs-drift.py --range origin/main..HEAD --gate

# 3. Publish a verified checkpoint (auto-pushes via .githooks/post-commit)
git commit -m "Describe change

Checkpoint: ready"
```

Enable checkpoint auto-push per clone with:

```bash
git config core.hooksPath .githooks
git config machinespirit.pushCheckpoints true
```

[`scripts/push-checkpoint.sh`](../scripts/push-checkpoint.sh) enforces a clean checkout, `git diff --check`, `gitleaks`, [`scripts/check-docs-drift.py`](../scripts/check-docs-drift.py) (keybind parity, broken links, PNG metadata stripping, visual audit coverage, and UI-surface freshness), Swift package test suites, Leader Key unit tests, and MachineSpirit app compilation before fast-forward pushing `main`.

---

## Repository Layout

```text
machine-spirit/
├── README.md                    # Flagship overview & showcase
├── VISION.md                    # Design thesis & principles
├── AGENTS.md / CLAUDE.md        # Multi-agent engineering contracts
├── CHECKPOINTS.md               # Restore doctrine & checkpoint ledger
├── MANUAL-WIRING.md             # Consent gates & manual setup steps
├── Brewfile                     # Declarative runtime dependencies
├── install.sh                   # Idempotent fresh-Mac bootstrap
├── app/MachineSpirit/           # Accessory overlay, Canvas board & Apps pane
├── kit/MachineSpiritKit/        # Node model, round-trip ConfigWriter, layouts
├── forks/                       # Owned Leader Key + Rectangle MIT forks
├── tools/ms/                    # Native Swift CLI + stdio MCP server
├── docs/
│   ├── REFERENCE.md             # This complete reference manual
│   ├── VISUAL-AUDIT.md          # Privacy & visible-text audit for every asset
│   ├── CHANGE-HISTORY.md        # Detailed commit & milestone history
│   └── img/                     # Audited screenshots and animated GIFs
├── bin/                         # AppleScripts, sheol-core, tor-session.py, ms wrapper
├── config/                      # Templated Leader Key, Karabiner, iTerm2, tmux, launchd
├── shell/                       # aliases.zsh, inline image feed, 38 offline splash banners
├── scripts/
│   ├── sync.sh                  # Pull live config -> repo (__HOME__ templated)
│   ├── check-docs-drift.py      # Automated keybind, link, metadata & UI-drift evaluator
│   ├── push-checkpoint.sh       # Full verification gate + fast-forward push
│   └── macos-defaults.sh        # Reversible macOS defaults tweaks
└── .githooks/                   # pre-commit (gitleaks) & post-commit (checkpoint push)
```
