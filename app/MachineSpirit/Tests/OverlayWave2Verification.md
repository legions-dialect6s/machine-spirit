# Overlay wave 2 — 2026-11-19

Implemented only under `app/MachineSpirit/`. No commit, push, deployment, live
configuration/defaults writes, or installed-app restart. The required
`AppDelegate.override convenience init()` remains intact. XcodeGen registered
both new source files; `project.yml` already includes the entire Sources folder.

## Built

- 56pt skull, overshooting summon/glow, minimum 260ms visibility, cancellation
  of both delayed hide and in-progress close. Reopening retains the anchor and
  samples presentation values. Close uses three tinted copies and three masked,
  discretely jittering bands over 200ms while nodes retract.
- Event-time speed EMA, discrete ≤120ms scene shake, scaled shockwaves plus a
  second thin ring, masked glyph slices, and bounded arrival jitter. Layers
  are pooled; no drawing loop, repeating timer, or per-frame random work.
- Graphics disclosure: accent color, curvature/randomness/shake/glitch sliders,
  existing effect toggles, preview/HUD toggles, and reset. Palette updates reuse
  existing layers on the next summon; zero settings disable their effects.
- Space placement preview with exact CLI zones, 150ms transitions, faint fill,
  stroke-only glow, label, screen switching, and scoped mouse monitors.
- Both HUD URL styles without opening the board: all-screen Caps banners and
  a wrapping text card near the mouse. Non-activating/non-key panels; text click
  dismisses. Repeated URLs cancel the old expiry. One strict deadline wakeup
  avoids the coalescing delay observed with a plain ten-second asyncAfter.

## Verification

The requested unsigned Debug build passes. The only final incremental warning
is the existing AppIntents metadata notice. `Tests/run-fx-smoke.sh <scratch>`
compiles and runs the following against the Debug dylib:

- `OverlaySceneSmoke`: 1,248 live-config layouts, including bounds and collisions.
- `PlacementGeometrySmoke`: 507 comparisons against the actual CLI
  `tools/ms/Sources/ms/WindowGeometry.swift`, including all zones, exact 10%/90%
  thresholds, out-of-frame points, negative origins, and vertically stacked screens.
- `StatsSmoke`: existing stats regression plus new FX defaults, bounds, invalid
  color fallback, reset isolation, and EMA idle decay. Preferences are in-memory.
- `OverlayLayerSmoke`: pooled layer identities, skull geometry, animation
  interruption, invalid paths/config replacement, no hidden animations, zero
  effect knobs, custom accent, and next-summon palette refresh. Preference changes
  use a volatile argument domain, not persistent defaults.
- `OverlayIPCSmoke`: real distributed notifications in a private namespace.
  70ms keys reach intensity 1.0; 600ms keys reach 0.0. The final short-show
  run began its close at 262.16ms (sampled in 5ms increments). Tests include successful
  hold repeats, show/hide within 35ms, continued visibility before 260ms, ghost
  close, reopen during close, cancellation of a pending hide, four preview mouse
  coordinates and frame assertions, monitor removal on hold/path/hide, both Caps
  states on all three attached screens, text click/ten-second expiry, replacement
  HUD deadlines, and no board/focus activation.

`top -pid <harness> -l 5 -s 1` records **0.0% CPU in every interval sample** for
both settled visible and hidden states. This is the isolated overlay process,
not a measurement of the installed app or WindowServer. No claim about compositor
frame rate is made.

Screenshots and raw build/test/CPU logs are in the supplied `specs/out/fx` scratch
directory, outside git: root, feedback, fast/slow typing, ghost, four preview
zones, Caps ON/OFF on each screen, text HUD, and Graphics controls. Window-targeted
captures avoid collecting the desktop. Preview PNG center alpha is asserted
below 6% (observed 3.53%); transparent PNG viewers can display its unassociated
RGB as bright green even though its actual fill is faint.

## Human checks

Physical Caps/space delivery from the fork, live mouse-monitor delivery and
cross-display movement, clicking the color well/sliders in the actual board,
and the subjective feel of the short summon/glitch/ghost transitions remain
integration checks. The automated preview supplies synthetic coordinates to the
same monitor callback implementation; it does not inject physical input or
execute window-placement binds. The HUD URL dispatcher is exercised directly,
without routing test URLs through LaunchServices to the installed app. Screen
hot-unplug and real 120/144Hz presentation cadence are not certified here.
