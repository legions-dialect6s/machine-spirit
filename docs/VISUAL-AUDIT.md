# README visual audit

Captured and visually reviewed against the running installed apps. Every final PNG and GIF in `docs/img/` was reopened and visually inspected (including extracted keyframes for animated GIFs) after compression and metadata stripping. This audit covers the active `docs/img/` showcase set.

No full-desktop screenshot was taken. Overlay captures used only graph rectangles over a temporary borderless `#0b0f0c` window. The menu-bar image used the status item's Accessibility frame; the menu and board were identified through WindowServer metadata and captured by their window IDs, without shadows. No real clipboard history was opened. Simulated overlay captures post navigation/feedback notifications only; no live binds are executed and no config is modified.

## Image inventory

| File | Pixels / Format | Description | Treatment |
|---|---:|---|---|
| [overlay-walk.gif](img/overlay-walk.gif) | 760 × 575 (20 fps GIF) | Live Core Animation overlay walkthrough: root skull bloom → `s` → `s/s` → backspace retract → root → `g` branch → blue completion pulse → collapse. | Captured strictly over a borderless `#0b0f0c` backdrop window; 6 keyframes visually audited; zero desktop pixels or personal data. |
| [display-half-steps.gif](img/display-half-steps.gif) | Animated GIF | Replay of seven WindowServer rectangles stepping across an external M28U above a MacBook Pro via `ddd`, `xxx`, and `www`. | Synthetic diagram redrawn from observed WindowServer bounds; zero desktop pixels. |
| [hero.png](img/hero.png) | 1320 × 1060 PNG | Center-anchored `s` navigation branch on a plain dark background. | Tight region capture; no personal text present; metadata stripped. |
| [overlay-corner.png](img/overlay-corner.png) | 1000 × 1240 PNG | The same `s` branch fanning inward from the top-left corner. | Crop starts below the menu bar; focus circle intentionally clipped at top; metadata stripped. |
| [menubar.png](img/menubar.png) | 798 × 48 PNG | Live compact status item with vertical group dividers, T3 ratio, CPU/GPU/RAM/MPRS/TEMP, hardware-classified drives (`SSD1`, `SSD2`, `SSD3`, `TM`), and upright keep-awake molecule. | Native 2× AX-frame capture of the single status item; displays generic hardware labels only (no volume names); all text/EXIF/time chunks stripped. |
| [menu.png](img/menu.png) | 519 × 472 PNG | Compact system menu, including terminal controls, brightness slider, keep-awake, and clipboard. | Session names, commands, and ages blurred (`CIGaussianBlur`, radius 24) before committing; metadata stripped. |
| [clipboard.png](img/clipboard.png) | 1040 × 880 PNG | Production AppKit clipboard panel with two synthetic entries. | Rendered with fixture strings; no live clipboard access; metadata stripped. |
| [board.png](img/board.png) | 1000 × 700 PNG | Close-up of the MachineSpirit Canvas board at close zoom. | Window-only capture; ledger closed; no paths or session titles visible; metadata stripped. |

All PNGs are verified by [`scripts/check-docs-drift.py`](../scripts/check-docs-drift.py) to contain zero `tEXt`, `iTXt`, `zTXt`, `eXIf`, or `tIME` metadata chunks while preserving color-profile chunks.

## Visible-text audit

### overlay-walk.gif (6 extracted 1-second keyframes inspected)

- **Root bloom (`sec_01.png`, `sec_05.png`):** Green skull center; top-level nodes `1` (`window first-third`), `2` (`window center-third`), `3` (`window last-third`), `y` (`invoke web-jump youtu…`), `←` (`Move to display left`), `Clipboard history`, `z` (`window bottom-left`), `-` (`invoke win-lerp`), `=` (`invoke win-lerp 120`), plus single-letter group discs (`a`, `b`, `c`, `e`, `g`, `h`, `i`, `l`, `m`, `n`, `p`, `q`, `s`, `space`, `t`, `u`, `v`, `w`, `x`).
- **`s` branch (`sec_02.png`, `sec_04.png`):** Green skull ancestor; `s` focus; children `a` (`invoke app-jump Safari`), `e` (`System Settings`), `i` (`invoke app-jump Signal`), `p` (`open app Spotify`), `x` / `t` (`invoke web-jump x.com…`), `s` (`s-s`), `l` (`😴 sleep`), `h` (`s-h-o`).
- **`s/s` branch (`sec_03.png`):** Green skull → `s` → `s` breadcrumb; children `f` (`invoke ss-finder`), `m` (`invoke ss-menu`), `w` (`s-s-w`), `s` (`s-s-s`), `r` (`s-s-r`).
- **`g` branch + electric-blue completion pulse (`sec_06.png`):** Blue-pulsed `g` center + skull; children `i` (`invoke web-jump githu…`), `r` (`invoke web-jump grok.…`), `m` (`Gmail`), `o` (`invoke web-jump googl…`), `g` (`Previous display`), `p` (`open app ChatGPT Clas…`), `w` (`invoke web-jump chatg…`).
- Zero menu bar pixels, zero other windows, zero personal names, machine names, filesystem paths, IPs, emails, or live session titles.

### display-half-steps.gif

- Redraws seven observed WindowServer rectangles from a disposable window on an M28U above a Mac laptop. Each frame shows the command (`ddd`, `xxx`, `www`), display label, and landing half. Zero desktop pixels.

### hero.png

- Labels: `😴 sleep`; `invoke app-jump Safari`; `open app System Setti…`; `invoke app-jump Signal`; `open app Spotify`; `s-s`; `invoke web-jump x.com…` (twice).
- Key glyphs: `a`, `e`, `f`, `g`, `i`, `l`, `m`, `p`, `r`, `s`, `t`, `w`, `x`; dim `⇪` ancestor.
- No personal text, paths, or desktop chrome.

### overlay-corner.png

- Same `s` branch labels and glyphs as `hero.png`, anchored near top-left; crop starts cleanly below the menu bar.

### menubar.png (updated 2026-11-22)

- Shows the skull mark, `T3 1/5`, vertical divider, `CPU 18%`, `GPU 40%`, `RAM 61%`, `MPRS 1/3` (mint), `TEMP 69°`, vertical divider, `SSD1 151G`, `SSD2 87G`, `SSD3 96G`, vertical divider, `TM 3.1T`, and the bright upright keep-awake molecule.
- Generic hardware labels only — zero personal drive names, neighboring menu items, or window pixels. PNG metadata chunks (`tEXt`/`iTXt`/`zTXt`/`eXIf`/`tIME`) stripped and verified.

### menu.png

- Summary: `CPU 49% · GPU 23% · MEM 55% · 84°C · ↓0.0 ↑0.0 MB/s · 80%`.
- Static rows: `Terminals & tmux`; `More…`; `New tmux window`; `New terminal window`; `Open sheol ledger…`; `Brightness`; `Keep awake: off`; `Clipboard history…`; `Leader Key`; `Quit MachineSpirit Leader Key`.
- Redaction covers the session text block (`x=20, y=50, w=268, h=181`) with Core Image `CIGaussianBlur`, radius 24; no session names, commands, or paths are legible.

### clipboard.png

- Synthetic fixture strings only: `Clipboard history`; `2 / 2`; `Search clipboard…`; `Alpha clipboard preview — clean native typography`; `Beta clipboard entry`; footer shortcut legend.

### board.png

- Window header: `machine-spirit`, `+++ machine-spirit +++`, `sheol`, `refresh`, `node graph`.
- Controls: `−`, `+`, `radial`, `⇄`, `hand`, `sort`, `+` / `−`.
- Footer: `165 nodes · imported live · pen wired`; `⌁ sheol is empty`; `type keys to walk · esc root · ⌫ up · ⌘R refresh`.
- No personal paths, session titles, or identifying text visible.

## Automated checks

[`scripts/check-docs-drift.py`](../scripts/check-docs-drift.py) enforces on every `Checkpoint: ready` push:
1. 100% keybind parity between `config/leader-key/config.json` and `docs/REFERENCE.md` / `README.md`.
2. Zero broken local links or image paths in `README.md` and `docs/REFERENCE.md`.
3. Every file in `docs/img/` is audited here, under the 4 MiB limit, and (for PNGs) carries zero forbidden metadata chunks.
4. Any checkpoint touching a mapped UI surface must either refresh its corresponding docs/visuals or include an explicit `Visuals-Reviewed: current` / `Docs-Reviewed: current` trailer.
