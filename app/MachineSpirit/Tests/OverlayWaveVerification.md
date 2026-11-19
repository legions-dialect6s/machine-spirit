# Overlay wave — 2026-11-19

Implemented within `app/MachineSpirit/`: vector skull/root and focus mark; spring letters; three pooled shockwaves; miss/back/done/hold feedback; persistent hold state; interruptible retracting close; non-key clickable nodes and hover routes; visible-frame layout; optional curved traces; backing-scale/edge antialiasing; transient board; opt-in local stats and board controls. All new overlay effects use `OverlayFX` preferences. XcodeGen regenerated the project.

Two additional lifecycle fixes: late back feedback cannot overwrite a pending hide or reopen a hidden panel, and the board no longer recenters its viewport on every appearance. Closing removes the mouse monitors immediately and clears remaining CA animations at completion. There are no new repeating clocks or polling loops.

## Verified

- Requested unsigned Debug build: **passed**. Final incremental build reported only the existing AppIntents metadata notice. The initial full build also emitted existing SwiftTerm/ITermColors actor-isolation warnings.
- `OverlaySceneSmoke`: **960 live-config layouts passed**, across three screen sizes and center/edge/corner anchors, now including menu/Dock safe rectangles and non-root disc bounds. Worst geometry case in that run: **6.619 ms**.
- `OverlayLayerSmoke`: **passed**. Stable layer identity across 50 show/hide pairs and 50 navigation requests; exactly three rings; spring animation; red/blue feedback; ancestor/preview hover highlighting and hit testing; non-key/non-main panel; matching backing scales and edge antialiasing; interrupted close; invalid-path recovery; stale-back rejection; no surviving hidden animations; model replacement/removal.
- `ConfigWatcherSmoke`: **passed**, including atomic replacement, deletion/recreation, parent replacement, acknowledged writes, and stop. Only disposable test files were changed.
- `StatsSmoke`: **passed**, with in-memory preferences and a scratch JSON file. Default opt-out, ten-second debounce (no file after nine seconds), round-trip persistence, disable/reset cancellation including no resurrection after ten seconds, top-50 persistence, 60 calendar days, placement estimates, FX defaults/bounds, and skull geometry.
- `OverlayIPCSmoke`: **passed**, delivering real distributed notifications to the production delegate in a private namespace: root → a → a/m → miss → back → hold → fired → hold pulse → done → hidden. Hold remains visible; the panel never becomes key. Opt-in fires count once; legacy URL pings do not count. Closing without persistence preserves selected node, zoom, and pan.

The final IPC fixture contained seven nodes / 64 layers on a 2× display. Root first-content commit was **1.040 ms**, full fan **3.304 ms**, total handler **28.268 ms**. Subsequent navigation receipt-to-commit ranged **0.243–13.147 ms**. These are shared-desktop, small-fixture observations, not full-config latency or frame-pacing guarantees.

`top -l 5 -s 1` showed **0.0% CPU in all four interval samples** after the initial row, both for settled visible hold and settled hidden state. This measures the isolated overlay harness, not the installed app or WindowServer.

Captured with `screencapture -x -l <panel-window-id>` and visually inspected: `root.png`, `miss.png`, `done.png`, `hold.png`. The final captures show the green skull, full red flash, blue route, and settled green held route. They and raw CPU/IPC/build/test logs are in the task-supplied scratch directory, outside git. Window-targeted capture avoids capturing the wrong display when the pointer moves. Every harness exited afterward.

## Limits and deviations

Physical Caps/Karabiner hold delivery, a real click reaching the running fork without disturbing its focus, full SwiftUI transient-board deactivate/reopen/⌘Q behavior, non-Retina visual appearance, display hot-unplug, and actual refresh-rate pacing still require integration/human checks. The transient viewport retention is tested at the state level; the recenter fix is code-reviewed. No new TCC grant was requested.

Verification deliberately used the Debug dylib in a synthetic, privately namespaced harness instead of launching another production-bundle app or sending test events to the installed app. No binds were executed. No live config/defaults/app-support data was edited, no running app was restarted or redeployed, and nothing was staged, committed, or pushed. Stats persistence was tested only in scratch. No feature-scope deviations; only the verification isolation above. Stats flush pending counts on normal quit as well as after the ten-second quiet period; only retained top-50 path counts survive relaunch, while totals include every fire.

## Reproduce harnesses

After the README's Debug build, from `app/MachineSpirit`:

```sh
products="$PWD/DerivedData.noindex/Build/Products/Debug"
scratch="$(mktemp -d /private/tmp/ms-overlay.XXXXXX)"
for test in OverlayLayerSmoke StatsSmoke OverlayIPCSmoke; do
  swiftc -swift-version 6 -parse-as-library -I "$products" "Tests/$test.swift" \
    "$products/MachineSpirit.app/Contents/MacOS/MachineSpirit.debug.dylib" \
    -Xlinker -rpath -Xlinker "$products/MachineSpirit.app/Contents/MacOS" \
    -o "$scratch/$test"
done
"$scratch/StatsSmoke" "$scratch"
"$scratch/OverlayLayerSmoke"
MS_OVERLAY_DIAGNOSTICS=1 "$scratch/OverlayIPCSmoke" "$scratch"
```

Run UI harnesses sequentially so their panels do not overlap in captures. The geometry/config-watch compilation recipes remain in their test source headers; substitute `DerivedData.noindex` for older `DerivedData` build-product paths.
