# FX owner follow-up — 2026-11-19

Scope: `app/MachineSpirit/**`, in the `fx` worktree. No commit, deployment,
installed-app restart, live preference write, or LaunchServices test routing.
`AppDelegate.override convenience init()` is unchanged by this follow-up.

## Changes

- Caps is a 240×40pt click-through, non-key pill on every display, centered
  10pt below the top of `visibleFrame`. Glass composites 15% accent over 55%
  near-black (61.75% resulting alpha), with a 1.25pt outline and soft accent
  glow. ON uses `#FF5A3C` for its outline/text; OFF uses the configured accent.
- Caps enters down 8pt over 160ms, holds 1.1s, then fades up over 220ms.
  Repeat toggles reuse the windows and reset expiry. A toggle during exit
  reverses from presentation, with stale completion/deadline guards. Card
  bounds/position are set independently of translation to avoid a reversal jump.
- Caps/title typography is DIN Condensed Bold, uppercase with 0.8pt tracking;
  fallback is Avenir Next Condensed Demi Bold, then system condensed. Text
  body uses the regular 13pt system font. The text card uses the same glass.
  Missing content no longer produces default copy; an empty text payload shows
  nothing. The screenshot fixture is `Hola mundo → Hello world`.
- Hover scales the node and route by 1.08 with a 140ms spring, brightens their
  traces/glow, and dims other nodes. Those nodes drift radially 6–14pt with
  distance falloff and Randomness-scaled variation. Screen-edge travel is
  reduced to keep labels visible. Highlighted route centers stay fixed;
  other trace endpoints follow their nodes. Hover-out restores over 200ms.
- Hit-testing uses stable layout centers, preview scale, and label bounds.
  Hover targets are computed once per change; animations sample presentation
  on interruption. No per-frame Swift work or repeating timer was added.
  Hidden backing discs do not receive redundant glow animations.

## Verification

The prescribed unsigned Debug build passes (only the existing AppIntents
metadata notice). `Tests/run-fx-smoke.sh <scratch>` compiles and exercises the
actual Debug dylib. Follow-up assertions cover scale/spring timing, radial
travel, fixed routes, stable hit regions, interruption/navigation, deterministic
zero-randomness targets, effect-off/zero-duration behavior, and layer reuse.

HUD checks cover each attached screen's frame, 240×40 geometry, 10pt top gap,
fill alpha, state colors, display font/tracking, regular 13pt body, non-key and
click-through flags, same-window toggle updates, stale deadlines, fade reversal
without vertical shift, empty payloads, text click/expiry, and board isolation.
The standalone harness flushes Core Animation before waiting, matching the
transaction submission normally supplied by AppKit's event loop.

Final run: **all five smoke harnesses pass**. This includes the prior wave's
1,260 live-config layout checks, 507 comparisons against CLI placement math,
Stats/FX checks, 70ms versus 600ms input, minimum summon dwell, interrupted
close, pooled effects, preview monitors, and URL isolation. `git diff --check`
is clean.

All five samples from `top -pid <harness> -l 5 -s 1` read **0.0% CPU** in each
of four states: settled hover, restored after hover-out, ordinary visible, and
hidden (20 samples total). These are the isolated harness process, not the
installed application or WindowServer. Finite animations have elapsed at rest;
CA can retain expired client animation objects until a later transaction, so
settled assertions check local end times rather than requiring pruned keys.
Hidden close still requires an empty animation tree.

Captures were reopened and visually inspected: `caps-on-0/1/2.png`,
`caps-off-0/1/2.png` (all three displays, including 1× and 2× backing scales),
`hud-text.png`, `hover-spores.png`, and `hover-out-settled.png`. Pill position,
size, colors, glass alpha, and typography are also asserted against the live
window/layer objects. Transparent window captures exclude the desktop; a viewer
that ignores alpha may show the faint green glow as bright green.

The original spec's screenshot directory now contains a `followup/` subdirectory
with these captures, `build.log`, all five harness logs, and `cpu-HOVER.log`,
`cpu-RESTORED.log`, `cpu-VISIBLE.log`, and `cpu-HIDDEN.log`.
Reproduce with the prescribed Debug build followed by
`Tests/run-fx-smoke.sh <original-scratch-directory>/followup`.

## Remaining human check

Subjective motion feel and physical fork/mouse delivery remain live integration
checks. Tests use private distributed notifications and direct hover/URL calls;
they neither execute binds nor replace the running installed app. No claim is
made about WindowServer CPU or certified display frame cadence.
