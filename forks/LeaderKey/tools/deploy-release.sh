#!/bin/bash
set -euo pipefail
FORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_APP="$HOME/Applications/MachineSpirit Leader Key.app"
LOG="${1:-/private/tmp/machinespirit-fork-build.log}"
xcodebuild -project "$FORK_DIR/Leader Key.xcodeproj" -scheme 'Leader Key' \
  -configuration Release -derivedDataPath "$FORK_DIR/DerivedData-Release.noindex" \
  -skipPackagePluginValidation -skipMacroValidation clean build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1
# Quit cleanly to restore ColorSync and release assertions before replacing files.
osascript -e 'tell application id "com.machinespirit.leader-key" to quit' || true
launchctl bootout "gui/$(id -u)/com.machinespirit.leader-key" 2>/dev/null || true
rm -rf "$FORK_APP"
ditto "$FORK_DIR/DerivedData-Release.noindex/Build/Products/Release/Leader Key.app" "$FORK_APP"
codesign --force --deep -s 'MachineSpirit Local Codesign' "$FORK_APP"
codesign --verify --deep --strict "$FORK_APP"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.machinespirit.leader-key.plist"
launchctl print "gui/$(id -u)/com.machinespirit.leader-key" | sed -n '1,28p'
