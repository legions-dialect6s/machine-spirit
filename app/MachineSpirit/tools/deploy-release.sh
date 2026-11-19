#!/bin/bash
# Stable daily-driver install; build products stay out of Spotlight.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/MachineSpirit.app"
DERIVED_DATA="$APP_DIR/DerivedData-Release.noindex"
LOG="${1:-/private/tmp/machinespirit-board-build.log}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CERT_CN="MachineSpirit Local Codesign"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcodebuild -project "$APP_DIR/MachineSpirit.xcodeproj" -scheme MachineSpirit \
  -configuration Release -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation -skipMacroValidation clean build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1 \
  || { echo "Board build failed; see $LOG" >&2; exit 1; }

# Same per-machine identity as install.sh's launcher; no Apple account needed.
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
  cat > "$WORK/x.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$CERT_CN
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$WORK/k.pem" -out "$WORK/c.pem" \
    -days 3650 -nodes -config "$WORK/x.cnf" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/k.pem" -in "$WORK/c.pem" -out "$WORK/id.p12" \
    -passout pass:ms-temp -macalg sha1 -name "$CERT_CN" >/dev/null 2>&1
  security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P ms-temp -A >/dev/null 2>&1
fi

# Validate the replacement before disturbing the running app.
ditto "$DERIVED_DATA/Build/Products/Release/MachineSpirit.app" "$WORK/MachineSpirit.app"
codesign --force --deep -s "$CERT_CN" "$WORK/MachineSpirit.app"
codesign --verify --deep --strict "$WORK/MachineSpirit.app"
if pgrep -x MachineSpirit >/dev/null; then
  osascript -e 'quit app id "com.machinespirit.MachineSpirit"' || pkill -x MachineSpirit || true
  for _ in {1..50}; do
    pgrep -x MachineSpirit >/dev/null || break
    sleep 0.1
  done
  if pgrep -x MachineSpirit >/dev/null; then
    pkill -x MachineSpirit || true
    for _ in {1..50}; do
      pgrep -x MachineSpirit >/dev/null || break
      sleep 0.1
    done
  fi
  if pgrep -x MachineSpirit >/dev/null; then
    echo "Board did not quit; leaving the installed copy untouched." >&2
    exit 1
  fi
fi
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$WORK/MachineSpirit.app" "$APP"
codesign --verify --deep --strict "$APP"
"$LSREGISTER" -f "$APP"
# Include pre-migration paths as well as current .noindex build locations.
for dir in DerivedData DerivedData-Release DerivedData.noindex DerivedData-Release.noindex; do
  for configuration in Debug Release; do
    product="$APP_DIR/$dir/Build/Products/$configuration/MachineSpirit.app"
    # Already-unregistered products can return -10814; cleanup is idempotent.
    if [[ -d "$product" ]]; then "$LSREGISTER" -u "$product" || true; fi
  done
done

# The fork's msLaunchBoardAtLogin already owns startup. Remove the old duplicate.
if ! osascript -e 'tell application "System Events" to delete every login item whose name is "MachineSpirit"'; then
  echo 'Warning: remove MachineSpirit from System Settings > General > Login Items manually.' >&2
fi
open -g "$APP"
echo "Installed and launched $APP (build log: $LOG)"
