#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="${1:?Pass a scratch output directory}"
mkdir -p "$scratch"
products="$PWD/DerivedData.noindex/Build/Products/Debug"
for test in OverlayLayerSmoke StatsSmoke OverlayIPCSmoke; do
  swiftc -swift-version 6 -parse-as-library -I "$products" "Tests/$test.swift" \
    "$products/MachineSpirit.app/Contents/MacOS/MachineSpirit.debug.dylib" \
    -Xlinker -rpath -Xlinker "$products/MachineSpirit.app/Contents/MacOS" -o "$scratch/$test"
done
swiftc -swift-version 6 -parse-as-library -I "$products" Tests/PlacementGeometrySmoke.swift \
  ../../tools/ms/Sources/ms/WindowGeometry.swift \
  "$products/MachineSpirit.app/Contents/MacOS/MachineSpirit.debug.dylib" \
  -Xlinker -rpath -Xlinker "$products/MachineSpirit.app/Contents/MacOS" -o "$scratch/PlacementGeometrySmoke"
swiftc -swift-version 6 -parse-as-library -I "$products" Sources/OverlayScene.swift Sources/NodePresentation.swift \
  Tests/OverlaySceneSmoke.swift "$products/MachineSpiritKit.o" -o "$scratch/OverlaySceneSmoke"
"$scratch/PlacementGeometrySmoke" > "$scratch/geometry.log" 2>&1
"$scratch/OverlaySceneSmoke" > "$scratch/scene.log" 2>&1
"$scratch/StatsSmoke" "$scratch" > "$scratch/stats.log" 2>&1
"$scratch/OverlayLayerSmoke" > "$scratch/layers.log" 2>&1
MS_OVERLAY_DIAGNOSTICS=1 "$scratch/OverlayIPCSmoke" "$scratch" > "$scratch/ipc.log" 2>&1 &
harness_pid=$!
# Target only our private harness, never MachineSpirit.app.
for state in HOVER RESTORED VISIBLE HIDDEN; do
  until rg -q "$state settled" "$scratch/ipc.log"; do
    if ! kill -0 "$harness_pid" 2>/dev/null; then wait "$harness_pid"; exit 1; fi
    sleep 0.2
  done
  top -pid "$harness_pid" -l 5 -s 1 -stats pid,command,cpu,time > "$scratch/cpu-$state.log"
done
wait "$harness_pid"
printf 'PASS all FX smoke harnesses; logs and captures in %s\n' "$scratch"
