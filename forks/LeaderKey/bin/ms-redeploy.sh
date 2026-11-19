#!/bin/zsh
# Release-build the fork and redeploy it as the daily driver (re-signed with the
# stable local cert so TCC grants survive). Same recipe as AGENTS.md.
set -e
cd "${0:A:h:h}"
xcodebuild -project "Leader Key.xcodeproj" -scheme "Leader Key" -configuration Release \
  -derivedDataPath ./DerivedData-Release.noindex -skipPackagePluginValidation -skipMacroValidation \
  ${CLEAN:+clean} build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO > /tmp/lk-build.log 2>&1 \
  || { grep -E "error:" /tmp/lk-build.log | head; exit 1; }
APP="$HOME/Applications/MachineSpirit Leader Key.app"
BUILT="DerivedData-Release.noindex/Build/Products/Release/Leader Key.app"
launchctl bootout "gui/$(id -u)/com.machinespirit.leader-key" 2>/dev/null || true
rm -rf "$APP"; ditto "$BUILT" "$APP"
codesign --force --deep -s "MachineSpirit Local Codesign" "$APP" 2>/dev/null
# Never let LaunchServices resolve "Leader Key" to the build product.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BUILT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.machinespirit.leader-key.plist"
echo "redeployed"
