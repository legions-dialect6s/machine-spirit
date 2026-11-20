# Caps pointer badge — pass 3

Scope: `app/MachineSpirit/**` in the `fx` worktree. No commit, deploy,
installed-app restart, live preference write, or LaunchServices URL routing.
`AppDelegate.override convenience init()` is preserved.

The badge is 28×18pt, with a 4pt transparent glow margin (36×26pt window).
It uses the pill's green glass, a red-amber `#FF5A3C` stroke, and a single ⇪.
Its visible top-left sits 14pt right and 18pt below the pointer; edges flip
it left/up to stay on-screen. Backing scale follows the pointer's display.
The panel is click-through, nonactivating, never key/main, on all spaces and
fullscreen auxiliary, at status-window level (one below the leader overlay).

Launch and every HUD URL read `CGEventSource.flagsState(.hidSystemState)`;
current hardware wins if a URL's announced state is stale. Global/local
`flagsChanged` callbacks also read the current HID state instead of trusting
queued event bits. There is no polling. Local monitors cover events sent to
MachineSpirit itself. While enabled and ON, one global and one local monitor
handle mouseMoved/leftMouseDragged; each directly calls setFrameOrigin once.
OFF removes both mouse monitors immediately, fades in Core Animation for
150ms, then closes and releases the window. Rapid OFF→ON reuses the window
and invalidates stale completion callbacks. Dormant flags/preferences listeners
remain while OFF so the next external toggle can be detected.

`OverlayFX.capsFollower` defaults true. Graphics exposes “Caps pointer badge”;
changes apply immediately, independently of the transient HUD toggle.

Verification uses the actual unsigned Debug dylib and production delegate URL
routing. HID state is injected and defaults are in memory; actual Caps Lock
is never changed. Tests cover OFF startup, ON startup, repeated/stale URLs,
text-URL reconciliation, real local flagsChanged delivery, preference disable
and reenable, 150ms fade, rapid reversal, weak-reference window deallocation
after an autorelease-pool drain, monitor removal, and termination cleanup.
All three attached displays are checked, including negative origins, edge
placement, and 1×/2× scale. Actual local mouse/left-drag delivery and real global
mouse delivery from a separate event-generator process are exercised. The
pointer is restored afterward; no synthetic button press or bind is sent.

Reproduce with the README's unsigned Debug build, then:

```sh
bash Tests/run-fx-smoke.sh <scratch-directory>
# Follower-only run:
bash Tests/run-caps-follower-smoke.sh <scratch-directory>
```

Artifacts are in the original spec scratch directory's `follower/` subdirectory:
`build.log`, six harness logs, `cpu-follower-MOVING.log`,
`cpu-follower-OFF.log`, and `caps-follower-0.png` through `-2.png`.
All three badge captures were reopened and visually inspected. Window captures
preserve alpha; viewers without an alpha background can exaggerate the green glow.

Performance numbers cover only the isolated Debug harness, including its
AppKit event dispatch. They exclude the separate event generator, WindowServer,
and the installed application. The generator posts 1,200 mouseMoved events at
120 events/s over 10 seconds. `top -pid <harness> -l 5 -s 1` samples CPU;
the first 0.0 moving sample is top's initialization sample, not a moving result.

Physical Caps Lock/global keyboard delivery under the installed app's existing
Accessibility grant remains a live integration check; it was not redeployed.
Launch and HUD reconciliation do not depend on the global keyboard monitor.

Final result: prescribed unsigned Debug build green; all six smoke harnesses
pass, including 1,272 live-config layout cases and 507 CLI geometry comparisons.
The final generator posted 1,200 events in 10.0005s; follower movement was
observed in all 90/90 100ms samples. Moving CPU interval samples were 3.8%,
7.6%, 8.4%, and 7.8% (mean 6.9%). All five settled OFF samples were **0.0%**.
The earlier isolated run measured 4.4–7.7% moving and also five 0.0% OFF
samples; these are short Debug-process samples, not a whole-system estimate.
`git diff --check` is clean.
