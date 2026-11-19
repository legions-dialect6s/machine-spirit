# Typing overlay v3 verification — 2026-11-19

Built on the existing uncommitted v2. Edits are restricted to `app/MachineSpirit/`. No staging, commits, pushes, root README edits, fork edits, or live config writes were performed for this task.

## Implementation

- `Sources/TypingOverlay.swift`: persistent layer-hosting NSView, full-frame nonactivating panel at window level 26, mouse anchor, CA animation replacement from presentation values, immediate focus feedback, coalesced navigation, cached per-anchor layouts, diagnostic timing, and hidden-panel A/B switch.
- `Sources/OverlayScene.swift`: geometry only; edge/corner fan, full children, smaller grandchildren, ancestor chain, spatial collision buckets, and optional preview labels. Removed the old SwiftUI drawing clock and snapshots.
- `Sources/IconStore.swift`: cached CGImages and asynchronous favicon delivery into existing layers. Board image rendering remains supported.
- `Sources/GraphView.swift`: removed superseded overlay mode; board keeps Canvas/TimelineView.
- `Sources/AppState.swift`: model-change callback for rebuilding the overlay, including removal/failure recovery.
- `Sources/AppDelegate.swift`: register IPC observers before prebuilding the overlay.
- `Tests/OverlaySceneSmoke.swift`, `Tests/OverlayLayerSmoke.swift`, `Tests/OverlaySimulation.swift`: geometry, actual layer lifecycle, and live notification tests.
- App README updated; Xcode project regenerated with XcodeGen. The project already had uncommitted v2 changes when this task began.

The live config used 166 nodes / 1,331 layers. The root's visible neighborhood contained 100 nodes (focus, children, grandchildren); the tested `s` path contained 17 including its ancestor. Navigation does not create layers, paths, fonts, or image assets. Geometry and CAAnimation objects are computed on input; there is no application frame loop.

## Build and functional verification

The requested Debug / ad-hoc-sign build succeeded. The only build warning was the existing “No AppIntents.framework dependency found” metadata-extraction notice. `git diff --check` passed.

Geometry smoke: **960 layouts passed**, spanning all 80 live groups, three display sizes, and center/top/corner positions. Checks cover exact focus anchoring, all required neighborhood nodes, child bounds/collisions, grandchild scale/opacity/parent. Latest standalone geometry run's worst case was 5.730 ms; this is not the app's end-to-end timing.

Layer smoke: **passed**. A synthetic model exercises 50 immediate show/hide pairs plus 50 path changes; checks the final node, identical CALayer object identities across navigation, full screen frame, status level, click-through behavior, every layer's backing scale, interrupted close, invalid navigation during close, removed-focus recovery to root, config-triggered rebuild, and missing-config hide. It never edits the live config or executes a bind.

Live IPC: `spam` posts 50 show/hide pairs plus 50 path changes in tight loops, then an explicit final `s` selection. Viewed screenshot confirms `s`, full children, icons, dim grandchildren and ancestor. All logged navigations retain 1,331 layers. Notifications arriving in different runloop turns can produce multiple commits; only the latest pending state in each turn is applied.

## Timings and CPU

Debug build, three connected displays (reported maximum refresh rates 120, 144, 144 Hz; backing scales 2×, 1×, 2×). Other apps and another worker remained active. These are observations on a shared desktop, not isolated benchmark or frame-pacing certification.

The final renderer requests the display maximum via `CAAnimation.preferredFrameRateRange`. A fully hidden show first commits the prebuilt focus, flushes it, then places and commits the complete neighborhood. The diagnostic distinguishes `receipt` (first content commit) from `full` (complete neighborhood commit). Neither is a measured photon/display latency.

15 root opens, same anchor, first sample separated from the remaining 14:

| Measurement | Ordered-in / alpha 0 (selected) | orderOut on hide |
|---|---:|---:|
| First open: focus commit | 3.673 ms | 7.140 ms |
| First open: full neighborhood commit | 42.283 ms | 41.726 ms |
| Warm focus commit, median | 0.618 ms | 1.007 ms |
| Warm full neighborhood commit, median | 3.877 ms | 4.658 ms |
| Warm handler, median | 3.848 ms | 4.636 ms |
| Warm focus commit, maximum | 0.774 ms | 1.350 ms |
| Warm full neighborhood commit, maximum | 4.440 ms | 5.793 ms |

During 80 navigation changes spaced 60 ms apart, median receipt-to-commit was **3.796 ms**, maximum **10.156 ms**. The cold full-neighborhood cost includes a substantial first-render/flush cost, not just geometry (2.590 ms in that sample). **The <4 ms target is not universal:** the first focus response meets it in the selected-policy test, but cold full rendering and some navigation changes exceed it.

CPU sampled using `top -l 5 -s 1 -stats pid,command,cpu` with both process IDs. The first cumulative/initial row is excluded from interval summaries:

| Final CPU run | MachineSpirit samples (%) | WindowServer samples (%) |
|---|---|---|
| Before burst (startup/favicons still active) | 2.5, 4.0, 1.1, 1.6 | 38.9, 54.9, 44.8, 46.0 |
| Animation burst | 5.2, 6.8, 6.0, **7.1** | 52.0, 53.0, 52.3, **68.5** |
| After burst | 2.2, 2.4, 0.0, 0.5 | 27.9, 24.8, 27.9, 26.6 |
| Final settled hidden sample | **0.0, 0.0, 0.0, 0.0** | 14.2, 38.7, 49.1, 34.9 |

The final settled sample was taken from the final running build after its benchmark ended, with panel alpha 0. The app remains running. A separate earlier animation run peaked at **13.1%** MachineSpirit / **70.6%** WindowServer. WindowServer varied substantially with concurrent desktop activity, so the difference is not attributed exclusively to the overlay. Both hide strategies produced 0.0% idle readings; one final orderOut sample included a transient 0.2%. Ordered-in is selected for its lower show latency, not a claimed causal WindowServer reduction.

Raw evidence is local in `DerivedData/overlay-v3-*.log` / `.txt` (not intended for git): `final-warmtree`, `final-out`, `final-before`, `final-during`, `final-after`, `settled`, `final-out-settled`, `running-settled`, and `build`.

## Viewed screenshots

All four were opened and visually inspected. Main-display screenshots are Retina captures; circles, glyphs, icons, and label chips appear crisp. Small preview labels are intentionally tiny and dim at the requested 55% / 45% settings.

- `/private/tmp/ms-v3-center.png`: 28 full-size root children with smaller grandchildren and app/site icons; focus exactly at the sampled center.
- `/private/tmp/ms-v3-menu.png`: focus drawn over the menu-bar Edit area, with branches extending down into available space. Confirms the overlay is above the bar, not confined to visibleFrame. The upper part of the focus circle clips at the physical display edge because its center is 12 points below the top.
- `/private/tmp/ms-v3-corner.png`: root at the top-left corner; full-size children and smaller preview branches fan inward. No old distant-across-screen preview fallback.
- `/private/tmp/ms-v3-spam.png`: final `s` focus after the tight-loop spam, including System Settings, Spotify, X site icons, grandchildren, and dim ancestor. No stale root fan remains.

Screenshots remain outside the repo and include the existing desktop; do not publish them without checking/redacting surrounding content.

## Reproduce

From `app/MachineSpirit` after the requested xcodebuild:

```sh
swiftc -swift-version 6 -parse-as-library -I DerivedData/Build/Products/Debug \
  Sources/OverlayScene.swift Sources/NodePresentation.swift Tests/OverlaySceneSmoke.swift \
  DerivedData/Build/Products/Debug/MachineSpiritKit.o -o DerivedData/overlay-scene-smoke
DerivedData/overlay-scene-smoke

swiftc -swift-version 6 -parse-as-library -I DerivedData/Build/Products/Debug \
  Tests/OverlayLayerSmoke.swift \
  DerivedData/Build/Products/Debug/MachineSpirit.app/Contents/MacOS/MachineSpirit.debug.dylib \
  -Xlinker -rpath -Xlinker "$PWD/DerivedData/Build/Products/Debug/MachineSpirit.app/Contents/MacOS" \
  -o DerivedData/overlay-layer-smoke
DerivedData/overlay-layer-smoke

swiftc Tests/OverlaySimulation.swift -o DerivedData/overlay-simulation
DerivedData/overlay-simulation spam
screencapture -x /private/tmp/ms-v3-spam.png
DerivedData/overlay-simulation hide
```

Use `open --env MS_OVERLAY_DIAGNOSTICS=1 --stdout "$PWD/DerivedData/overlay.log" DerivedData/Build/Products/Debug/MachineSpirit.app` after terminating any prior instance. Add `--env MS_OVERLAY_ORDER_OUT=1` for the other policy. Keep diagnostics outside git; they log paths, counts, and timings but no command payloads.

## Limits / untested

Actual 120/144 Hz frame pacing, transient flash-free behavior at every display frame, physical Caps Lock/Karabiner delivery, exclusive fullscreen/Space transitions, and display hot-unplug are not certified by these tests. The config-rebuild behavior was tested with an in-memory synthetic model, not by modifying the owner's live file. Extremely small screens or arbitrarily dense future configs can still exhaust collision-free area. Cold full rendering remains the main measured performance limitation.

## Label and backdrop polish — 2026-11-19

The board and overlay previously both used `Node.displayName`, so unlabeled live groups really did say `group` / `gate` in both views. The sidecar has no name field. `Sources/NodePresentation.swift` now supplies the shared board/overlay resolver: explicit nonblank label, existing action-derived display name, an unambiguous single-child continuation's name, then the node's key path. Only nodes without any of those retain a type word. Branch names are key paths, not invented semantic categories. `GraphView.swift` uses the same resolver without truncation; overlay chips use at most 22 Swift Characters including the ellipsis. All overlay strings, fonts and measured chip widths are still prepared during model rebuilds only.

Live examples:

| Path | Before | After (overlay) |
|---|---|---|
| `1` | gate | window first-third |
| `s/i` | gate | invoke app-jump Signal |
| `s/s` | group | s-s |
| `s/l` | 😴 sleep | 😴 sleep |
| `t/q` | ✕ kill selected tmux pane  ◆◆◆◆ | ✕ kill selected tmux … |

`TypingOverlay.swift` owns one persistent radial `CAGradientLayer`, behind the edges and nodes and inside the existing fading scene. Its center follows the focused node; its circular radius covers the furthest visible disc/chip plus 32 points. It fades from black at 0.45 alpha to transparent, without a blur view, timer or drawing loop. Position and bounds use the existing presentation-value animation helper, including interrupted reopen. `OverlayScene.swift` computes its radius. This adds exactly one layer (1,332 for the current 166-node tree).

Validation: requested Debug build succeeded; app relaunched from DerivedData. The updated geometry smoke passed all **960 layouts** using actual measured label widths, with backdrop coverage checks. The layer smoke passed naming priority/fallback/truncation assertions, exactly one radial layer behind the graph, focus centering, fade inheritance, persistent gradient identity through config rebuild, and all existing navigation/lifecycle checks. Navigation retains layer identities. `git diff --check -- app/MachineSpirit` passed. No live config writes or bind execution.

Five final-build captures were opened and visually inspected:

- `/private/tmp/ms-polish-center.png`: dense root over a busy browser, readable labels and radial dim.
- `/private/tmp/ms-polish-group.png`: `s` children, explicit sleep label, Signal continuation name, `s-s` branch path.
- `/private/tmp/ms-polish-corner.png`: root fan at the upper-left; another app's active menu overlaps part of the graph during this shared-desktop capture.
- `/private/tmp/ms-polish-spam.png`: correct final `s` neighborhood after 50 show/hide pairs and 50 path changes.
- `/private/tmp/ms-polish-reopen.png`: close interrupted by reopening at the upper-left; focus and backdrop relocated together, with no stale center fan in the settled capture.

CPU: `top -l 6 -s 1 -stats pid,command,cpu`, excluding the first cumulative row. Shared desktop, other apps/workers active; WindowServer figures are whole-desktop observations, not overlay-only cost.

| Sample | MachineSpirit (%) | WindowServer (%) |
|---|---|---|
| Visible, settled | 0.0, 0.0, 0.2, 0.0, 0.0 | 40.5, 20.7, 66.4, 13.6, 19.4 |
| 80-navigation burst | 4.5, 6.9, 8.5, 6.3, 1.6 | 54.3, 52.7, 52.3, 55.6, 40.3 |
| Hidden, settled | 0.0, 0.0, 0.0, 0.0, 0.0 | 12.4, 12.2, 9.8, 8.9, 9.7 |
| Final rebuild/relaunch, hidden | **0.0, 0.0, 0.0, 0.0, 0.0** | 43.8, 45.5, 40.5, 35.4, 35.9 |

The first three samples precede the final unnamed-child fallback edge-case fix; the final row is from the final running build. The app is left running with its overlay hidden. Build, smoke and raw CPU evidence lives in `DerivedData/overlay-polish-*`. No new frame-pacing or latency claim is made. All task edits are under `app/MachineSpirit/`; concurrent root/fork edits were left untouched. Nothing staged, committed or pushed.
