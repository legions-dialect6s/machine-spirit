# MachineSpirit.app — the optional board

## Build and install

From the repo root, run `./app/MachineSpirit/tools/deploy-release.sh` (full Xcode
required). It builds into `DerivedData-Release.noindex`, uses the stable local
signing identity shared with the fork, installs to `~/Applications/MachineSpirit.app`,
and launches in the background. `install.sh` calls the same script. The fork
owns board startup via `msLaunchBoardAtLogin`; deployment removes the obsolete
`MachineSpirit` Login Item and unregisters build copies from LaunchServices.

For a Debug build from this directory:

```bash
xcodebuild -project MachineSpirit.xcodeproj -scheme MachineSpirit \
  -configuration Debug -derivedDataPath DerivedData.noindex \
  build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Keep build directories suffixed `.noindex` so Spotlight excludes them. Run the
installed Release app as the daily driver; use `tools/deploy-release.sh` to update it.

## Behavior

The app launches as an accessory with no window or Dock icon; `machinespirit://board` opens the single, resizable board (minimum 420×320).
Closing the board removes its view tree and Sheol polling, and returns the app to accessory mode; reopening the running app also summons the board. `machinespirit://board?transient=1` opens a transient board: losing app activation orders it out and suspends board work, preserving selection, zoom and pan in memory. A later ordinary board URL clears transient mode; ⌘Q still quits.
While typing in Leader Key, a transparent graph (click-through outside nodes) spawns at the mouse on its screen, then stays anchored for the session without taking focus.
IPC uses `DistributedNotificationCenter`: `com.machinespirit.leader.nav` carries string `state`, `path`, and `screen`; `com.machinespirit.leader.fired` carries string `path` (send with `deliverImmediately: true`).
The legacy `machinespirit://fired?path=…` pulse remains supported without opening the board; a filesystem watch keeps the live config current.

The v3 overlay is a layer-hosting NSView in one reusable NSPanel, covering the entire screen frame at status-window level + 1. The board keeps its Canvas renderer. The overlay has no SwiftUI view, frame timer, or per-frame app drawing: CALayer/CAShapeLayer/CATextLayer animations run in Core Animation, requesting the current display's maximum refresh rate. Every layer uses the screen's backing scale; shape layers enable edge antialiasing, and straight trace endpoints align to half pixels at 1×. App/site images come from IconStore's shared raster cache; favicon arrivals replace existing contents.

The whole config's layers and text are built at startup and on model changes. Navigation changes properties only. The root skull can occupy the original mouse point even over the menu bar or Dock; every non-root node and label is constrained to the screen’s visible frame. A focused letter stays at the mouse point where the safe frame permits; children are full size, grandchildren are 55% size / 45% opacity, and ancestors form a dim chain. Labels sit on dark rounded chips; preview labels appear only where space permits. Geometry in `Sources/OverlayScene.swift` fans away from screen edges, reserves children before previews, and caches visited layouts for the session anchor.

Open/navigation uses 140ms ease-out motion with 8ms child staggering (capped at 40ms total); back collapses in 90ms and close retracts/scales/spins nodes toward the root in 70ms, with a 200ms chromatic skull ghost. A summon remains visible for at least 260ms even if hide arrives immediately; reopening during a close preserves its anchor and presentation. A typed letter springs down from 2.4× over 220ms and emits a pooled 380ms shockwave. Miss flashes the graph red for 350ms with a double letter pulse; done pulses the lit route blue for 450ms. Hold presses pulse the fired letter. The 56pt root skull grows through 0.55 → 1.25 → 1.0 with a glow bloom; it and the small focus mark use the reusable even-odd vector path in `SkullMark.swift`. Animations replace their keyed predecessor using presentation values. Incoming notifications share one runloop mailbox; duplicate paths do nothing. A fully hidden open commits the prebuilt focus immediately, then commits the complete fan after placement; diagnostics report both times. An interrupted close retains the existing presentation instead of clearing it.

The default hide policy keeps the panel ordered in with alpha 0 and no running clock. An A/B comparison favored this over ordering out. Set `MS_OVERLAY_ORDER_OUT=1` to repeat the comparison; `MS_OVERLAY_DIAGNOSTICS=1` prints receipt-to-first-commit, receipt-to-full-fan-commit, handler time, layout time, visible-node count, and total layer count. Neither setting changes the Leader Key config.

`Tests/OverlaySceneSmoke.swift` checks 960 live-config layouts for anchor, children/grandchildren/ancestors, bounds, and child collisions. `Tests/OverlayLayerSmoke.swift` tests actual CA layer identity, scale, window level, input coalescing, hide interruption, invalid paths, and config replacement using a synthetic model. `Tests/OverlaySimulation.swift` posts real distributed notifications without executing binds: `center`, `menu`, `corner`, `edge`, `bottom`, `group`, `back`, `reopen`, `movie`, `rapid`, `spam`, `burst`, `bench`, `hide`. `spam` sends 50 show/hide pairs and 50 path changes without delays, then selects `s` (or another live group). See [the verification report](Tests/OverlayV3Verification.md) for measurements and commands.

A root placed closer than its radius to the physical screen edge is clipped by that screen; it intentionally stays exactly under the mouse. Tiny displays or configurations with more nodes than physical space permits can exhaust collision-free placement. Long labels are ellipsized; full action text remains available on the board. The renderer requests native cadence; actual 120/144 Hz frame pacing requires a compositor/instrumented capture to certify.


## Overlay controls and local stats

`OverlayFX` reads `msFX.<property>` from UserDefaults on each new overlay session. The board’s compact **Graphics** disclosure exposes an accent color well, Curvature/Randomness/Shake/Glitch sliders, effect toggles, and Reset to defaults. Values persist under `msFX.*` and apply on the next summon. `accentHex` defaults to `#36DE6A`; `curvature`, `randomness`, `shake`, and `glitch` default to 0.4, 0.35, 0.4, and 0.5, bounded to 0…1. All booleans default true except `curvedTraces` (false): `skull`, `skullGlow`, `letterPop`, `shockwave`, `miss`, `back`, `done`, `hold`, `close`, `hover`, `placementPreview`, `hud`, `capsFollower`. Duration keys are `openingDuration` (0.14), `popDuration` (0.22), `shockwaveDuration` (0.38), `missDuration` (0.35), `backDuration` (0.09), `doneDuration` (0.45), `holdDuration` (0.16), `closeDuration` (half opening), and `hoverDuration` (0.14; return uses 10/7 of this), in seconds. Zero disables that motion; invalid/out-of-range values are bounded. Curved traces use one quadratic path per existing trace layer. The graph’s effect layers are pooled before navigation, and closing cancels all remaining animations. Successful forward navigation and repeated hold keys drive an interval EMA: 450ms or slower is calm, 90ms or faster is full intensity. It controls 120ms discrete scene shake, larger/brighter shockwaves with a second thin ring at high speed, and masked letter slices. Arrival jitter is bounded by Randomness. There is no animation clock or idle decay loop; the next key incorporates the elapsed idle time.

While shown, local/global mouse-moved monitors enable input only over visible node or label rectangles. Hover scales the node and its route to 1.08× with a slight 140ms spring, brightens their traces/glow, and dims neighboring nodes. Hover leaves node centers and trace endpoints at their layout coordinates. Hover-out restores scale, glow and opacity over 200ms. Clicking opens `msleaderkey://navigate?keys=…` with textual keys (`space`) and `activates = false`; the overlay panel can never become key or main. Monitors are removed as hiding begins. Late feedback cannot reopen a hidden overlay.

Stats are off unless `msStatsEnabled` is true. Only valid distributed `leader.fired` events count; legacy URL pings and board pulses do not. `StatsStore` saves total fires, the top 50 key-path counts, daily counts for the last 60 calendar days, and an estimate of time saved (2.5 seconds per fire, 4 for a route containing a window-placement action). Only the retained top 50 counts survive relaunch; totals and saved-time estimates include all fires. Command text is inspected for classification but is never stored. There are no fine timestamps or network requests. The file is `~/Library/Application Support/MachineSpirit/stats.json`, written atomically after ten seconds without another fire; normal quit flushes pending counts. Reset cancels pending writes and deletes the file. Disable stops collection and pending writes, retaining previous saved totals. The board shows total/today/saved time, top five paths, Reset and Disable while enabled.

See [the wave verification report](Tests/OverlayWaveVerification.md) for the isolated IPC harness, captures, timing, tests and remaining human integration checks.


## Placement preview and HUD

Nav `shown` with textual path `space` opens a click-through outline on the screen
under the mouse. The preview owns mouse-moved monitors only in that state and
removes them on path change, hold, or hide. It uses the same 10% edge bands as
`ms win place smart`: corners select quarters, a single edge selects a half,
and the interior selects a centered 90% rectangle. Zones animate in 150ms;
setting `openingDuration` to zero disables this transition. The glow follows
the stroke and the interior fill is 3.5% alpha. Existing graph hover monitors
remain separate and retain their original shown-session lifetime.

- `machinespirit://hud?style=caps&state=on` (or `off`) shows a 240×40pt pill at the top-center of
  every screen, 10pt inside the visible frame. A small ⇪ and CAPS ON/OFF sit
  on one line: red-amber ON / configured accent OFF. It slides down 8pt while
  fading in over 160ms, holds for 1.1s, then fades up over 220ms. Repeated
  toggles update the existing windows and renew the hold; even an interrupted
  fade resumes from presentation without replacing the panels.
- `machinespirit://hud?style=text&title=Hello&text=Message` shows a wrapping card
  near the mouse, up to 420pt wide, held for ten seconds or dismissed by click.
  URL-encode the title and text; neither has default sample copy, and an empty
  payload shows nothing. Content exceeding the available screen height
  is truncated. Text/title input is bounded to avoid unbounded layout work.

Both surfaces use 15% accent over 55% near-black glass with a 1.25pt stroke
and soft accent glow. Display text uses DIN Condensed Bold, falling back to
Avenir Next Condensed Demi Bold and then system condensed, uppercase with
0.8pt tracking. Text-card body copy uses the regular 13pt system text font.

Both URL styles bypass the board and never activate or become key. Only the
text card receives clicks. `hud` disables HUDs; `close`/`closeDuration=0` disables
the fade; `openingDuration=0` disables entrance motion. One strict one-shot deadline handles HUD expiry; Core Animation owns
the fade, with no per-frame Swift timer.

While Caps Lock is ON, a 28×18pt glass ⇪ badge follows the mouse, 14pt right
and 18pt below it (flipping at screen edges). Its red-amber `#FF5A3C` stroke
and glyph match the caps pill. One click-through, never-key window sits above
normal windows and below the leader overlay, including fullscreen spaces.
`msFX.capsFollower` defaults true; **Graphics → Caps pointer badge** applies
immediately and works independently of the transient `hud` toggle.

Launch, every HUD URL, and global/local `flagsChanged` events sample the current
HID Caps Lock state; current hardware wins over stale URL state. Mouse-moved
and left-drag monitors exist only while the badge is enabled and Caps is ON.
Each event directly sets the window origin, with no animation or polling timer.
OFF removes those mouse monitors immediately, fades for 150ms in Core Animation,
then closes and releases the window. Only dormant flags/preference listeners
remain. Global keyboard event delivery relies on macOS Accessibility access;
launch and HUD URL reconciliation work independently of that event delivery.

See [wave 2 verification](Tests/OverlayWave2Verification.md) for private IPC,
geometry parity, captures, CPU measurements, and remaining human checks.
Reproduce after the Debug build with `Tests/run-fx-smoke.sh <scratch-directory>`.

See [owner follow-up verification](Tests/OverlayFXFollowupVerification.md) for
pill, typography, spore motion, captures, and settled CPU checks.
