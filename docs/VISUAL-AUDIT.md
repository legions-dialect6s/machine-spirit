# README visual audit

Captured and visually reviewed on 2026-11-19 against the running installed apps. All six final PNGs were reopened and viewed after compression. This audit covers the new `docs/img/` set, not every historical image in the repository.

No full-desktop screenshot was taken. Overlay captures used only graph rectangles over a temporary borderless `#0b0f0c` window. The menu-bar image used the status item's Accessibility frame; the menu and board were identified through WindowServer metadata and captured by their window IDs, without shadows. No real clipboard history was opened. The simulation posts navigation notifications only; it does not execute binds or edit config.

## Image inventory

| File | Pixels | Description | Treatment |
|---|---:|---|---|
| [hero.png](img/hero.png) | 1320 × 1060 | Center-anchored `s` navigation branch on a plain dark background. | Tight region capture; no personal text present. |
| [overlay-corner.png](img/overlay-corner.png) | 1000 × 1240 | The same branch fanning inward from the top-left corner. | Crop starts below the menu bar; the focus circle is intentionally cut at the top. |
| [menubar.png](img/menubar.png) | 494 × 66 | The installed status item on the laptop display. | Native 2× crop of the 247 × 33-point WindowServer frame. |
| [menu.png](img/menu.png) | 519 × 472 | Compact system menu, including terminal controls and brightness. | Session names, commands, and ages blurred before copying into the repo. |
| [clipboard.png](img/clipboard.png) | 1040 × 880 | Production clipboard panel with two synthetic entries. | Copied from `forks/LeaderKey/docs/clipboard-panel.png`; no live clipboard access. |
| [board.png](img/board.png) | 1000 × 700 | Close-up of the board's root and branches at the existing zoom. | Window-only capture; the optional ledger is closed. No paths or session titles are visible. |

PNG optimization preserves the decoded scanline bytes exactly: lossless DEFLATE recompression plus removal of timestamp, EXIF, and text metadata. Color-profile/pixel-interpretation chunks are retained. Xcode's bundled `pngcrush` was tried, but its reduced output failed visual/decoder checks; those files were replaced from the reviewed originals. The final set totals about 1.13 MiB and every image is at most 1600 pixels wide.

## Two-display workflow replay

[display-half-steps.gif](img/display-half-steps.gif) redraws seven observed WindowServer rectangles from a disposable window on an M28U above a Mac laptop. The CLI fixture checked those rectangles against each display’s usable bounds. Each frame shows the command, display and actual landing half. Repeated no-op samples at the display edge were omitted. Frame duration is editorial. The GIF contains no desktop pixels.

For a timed portfolio video, record both displays with a disposable document. Show the same start and end positions first by dragging and then with Caps and the window shortcuts. Keep both clocks running through the final landing, show the dashed and solid previews at normal speed, and report both times and the number of repetitions. Use a separate close-up for the node graph and menu if their text is too small at two-display scale.

## Visible-text audit

Lists below transcribe distinct visible strings. Repeated labels and glyphs are listed once, with repetitions called out where useful. Ellipses in overlay labels are the application's own truncation. App icons, skulls, lines, dots, the slider, window controls, and brand marks are graphics, not personal text. Inspection included the tiny dim preview nodes; OCR was used only as a secondary check, not as evidence that an image is clean.

### hero.png

- Labels: `😴 sleep`; `invoke app-jump Safari`; `open app System Setti…`; `invoke app-jump Signal`; `open app Spotify`; `s-s`; `invoke web-jump x.com…` (twice).
- Node/preview key glyphs: `a`, `e`, `f`, `g`, `i`, `l`, `m`, `p`, `r`, `s`, `t`, `w`, `x`; a dim `⇪` ancestor.
- Icon lettering: `X` on the two public-site icons; `$|` on the script icons.
- No menu bar, other windows, notifications, personal names, machine names, account paths, IP addresses, email addresses, or chat/tab titles.

### overlay-corner.png

- Labels: `invoke app-jump Safari`; `open app System Setti…`; `invoke app-jump Signal`; `open app Spotify`; `😴 sleep`; `s-s`; `invoke web-jump x.com…` (twice).
- Node/preview key glyphs: `a`, `e`, `f`, `g`, `i`, `l`, `m`, `p`, `r`, `s`, `t`, `w`, `x`; a dim `⇪` ancestor. The top focus circle's own key is outside the crop.
- Icon lettering: `X`; `$|`.
- Only the graph and neutral background are present. The visible `x.com…` text is a configured public-site action, not a browser tab title or a personal hostname.

### menubar.png

- The capture shows the skull, T3 2/5, CPU 37%, GPU 50%, RAM 77%, kernel availability 44% in amber, temperature 69°, and the horizontal keep-awake molecule. All readings are instantaneous.
- The crop contains one status item. Neighboring menu items and windows are outside the capture. The saved PNG omits capture text and date metadata.

### menu.png

- Summary: `CPU 49% · GPU 23% · MEM 55% · 84°C · ↓0.0 ↑0.0 MB/s · 80%`, followed by a battery symbol.
- Static rows: `Terminals & tmux`; `More…`; `New tmux window`; `New terminal window`; `Open sheol ledger…`; `Brightness`; `Keep awake: off`; `Clipboard history…`; `Leader Key`; `Quit MachineSpirit Leader Key`.
- Shortcuts/controls: `⇧⌘V`, `⌘Q`, `+`, submenu chevrons, `$|` terminal marks, crescent/sleep marks, agent spark graphics, and red `×` controls.
- Redaction covers the session text block at image coordinates **x=20, y=50, width=268, height=181** (top-left origin). Core Image `CIGaussianBlur`, radius **24**, was applied only to that rectangle and composited back into the image. This covers all eight visible session names plus their commands/ages; those strings are no longer legible. No session text was transcribed into this audit.
- No username, hostname, IP, email, personal path, or chat/tab title remains visible. The menu was dismissed with Escape after capture.

### clipboard.png

- `Clipboard history`; `2 / 2`; `Search clipboard…`.
- `Alpha clipboard preview — clean native typography`; `Text`; `⌘1` and a pin graphic.
- `Beta clipboard entry`; `Text`; `⌘2`.
- Footer: `↵ Paste`; `⌥↵ Copy`; `⌘1–9 Choose`; `⌘P Pin`; `⌫ Delete (empty search)`; `Esc Close`.
- These are test fixture strings, not the owner's clipboard entries. No identifying data appears.

### board.png

- Window/header: `machine-spirit`; `+++ machine-spirit +++`; `sheol`; `refresh`; `node graph`.
- Controls: `−`, `+`, `radial`, `⇄`, `hand`, `sort`, and the add/remove `+` / `−` controls. A clipped `in` label fragment appears at the right viewport edge.
- Node keys and their repeated labels: `a`, `c`, `d`, `e`, `f`, `g`, `i`, `l`, `m`, `n`, `o`, `p`, `q`, `r`, `s`, `t`, `v`, `w`, `x`, and root `⇪`.
- Visible path labels: `s-s-w`, `s-s-s`, `s-s-r`, `s-s`, `f-a`, `f-d-o`, `f-d-o-w`.
- Footer: `165 nodes · imported live · pen wired`; `⌁ sheol is empty`; `type keys to walk · esc root · ⌫ up · ⌘R refresh`.
- No full action values, personal filesystem paths, session titles, usernames, hostnames, addresses, email, or chat/tab titles are visible. The node count is the board footer's non-root count; the engineering report's 166-node count includes the root.
- The board was closed with Cmd-W. Its original size, position, and zoom were restored after evaluating a wider capture.

## Rejected captures and cleanup

- An initial overlay crop included the edge of an unrelated system notification. It was rejected and deleted; the final crop excludes that area.
- Wider board captures exposed a dense field of overlapping action labels. Those captures were deleted; the delivered image is explicitly a close-up, not a full graph overview.
- `docs/showcase_v2.png`, an existing README image, still exposed personal account/path text and unrelated work despite older redaction overlays. It was deleted, and its embed removed. The older splash/board embeds were replaced or removed from the README; their technical documentation remains.
- The raw unredacted menu capture was deleted after the blurred version was reviewed. No real session was revived, detached, or killed; no clipboard entry was copied or pasted; no live bind was executed.
- The temporary black window was closed, the overlay hidden, and the board closed. All six requested filenames were delivered; no requested image is missing.

## Documentation checks

- Mermaid syntax parsed successfully; Markdown rendered with 41 headings, six tables, and exactly six image embeds.
- All 108 README link destinations/anchors were checked locally; referenced commit IDs resolve in git. The 70 distinct inline key-sequence references were checked against the captured config where they name a concrete sequence.
- `gitleaks dir --redact` found no secrets in the README or this audit. This supplements the visual inspection; it does not scan pixels for personal data.
- PNG dimensions, chunk checksums, compressed streams, and removal of text/EXIF/time metadata passed. Final decoded scanline bytes match the reviewed source captures.
- `git diff --check` passed. Changes are restricted to `README.md` and `docs/`; nothing was staged, committed, or pushed. No application source was changed or app test suite rerun for this documentation-only task.
