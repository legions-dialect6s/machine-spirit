#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="${1:?Pass a scratch output directory}"
mkdir -p "$scratch"
products="$PWD/DerivedData.noindex/Build/Products/Debug"
swiftc -swift-version 6 -parse-as-library -I "$products" Tests/CapsFollowerSmoke.swift \
  "$products/MachineSpirit.app/Contents/MacOS/MachineSpirit.debug.dylib" \
  -Xlinker -rpath -Xlinker "$products/MachineSpirit.app/Contents/MacOS" -o "$scratch/CapsFollowerSmoke"
"$scratch/CapsFollowerSmoke" "$scratch" > "$scratch/follower.log" 2>&1 &
harness_pid=$!
for state in MOVING OFF; do
  until rg -q "FOLLOWER $state" "$scratch/follower.log"; do
    if ! kill -0 "$harness_pid" 2>/dev/null; then wait "$harness_pid"; exit 1; fi
    sleep 0.1
  done
  top -pid "$harness_pid" -l 5 -s 1 -stats pid,command,cpu,time > "$scratch/cpu-follower-$state.log"
done
wait "$harness_pid"
printf 'PASS caps follower; logs and captures in %s\n' "$scratch"
