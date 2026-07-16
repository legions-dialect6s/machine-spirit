#!/usr/bin/env bash
# install.sh — reproduce this entire macOS setup on a fresh machine.
#
#   git clone <your-repo-url> ~/mac-setup && cd ~/mac-setup && ./install.sh
#
# Idempotent: safe to re-run. Existing configs are backed up (*.bak) before
# being overwritten. A few things CANNOT be scripted (macOS permissions) and
# are printed as a manual checklist at the end.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

backup_then_copy() {
  # backup_then_copy <src> <dest>
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    cp "$dest" "$dest.bak.$(date +%s)"
    echo "    backed up existing $dest"
  fi
  cp "$src" "$dest"
}

echo "==> 1/5  Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  echo "    installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Load brew into this shell (Apple Silicon path; Intel is /usr/local)
  if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
else
  echo "    already installed"
fi

echo "==> 2/5  Apps (brew bundle)"
brew bundle --file="$REPO_ROOT/Brewfile"

echo "==> 3/5  ~/bin scripts"
mkdir -p "$HOME/bin"
while IFS= read -r -d '' f; do
  rel="${f#"$REPO_ROOT/bin/"}"
  mkdir -p "$HOME/bin/$(dirname "$rel")"
  cp "$f" "$HOME/bin/$rel"
  chmod +x "$HOME/bin/$rel"
  echo "    installed bin/$rel"
done < <(find "$REPO_ROOT/bin" -type f -print0)

# Busy-pane shield (OPT-IN, off by default): symlink the iTerm2 API daemon into
# AutoLaunch so iTerm runs it, and drop the disable flag so it starts OFF (⌘W
# closes panes normally until you run shield-on.sh). Reversible — delete the
# symlink to remove. The ⌘W keybinding + Python API are the one-time manual step
# (see README "Busy-pane shield"). Compile the optional visual overlay too.
if [[ -f "$HOME/bin/pane-shield.py" ]]; then
  AL="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
  mkdir -p "$AL"; ln -sf "$HOME/bin/pane-shield.py" "$AL/pane-shield.py"
  mkdir -p "$HOME/.config/machine-spirit"; : > "$HOME/.config/machine-spirit/shield-disabled"
  echo "    linked busy-pane shield into iTerm AutoLaunch (OFF by default)"
  if command -v swiftc >/dev/null 2>&1 && [[ -f "$REPO_ROOT/assets/tools/shield-fx.swift" ]]; then
    swiftc -O "$REPO_ROOT/assets/tools/shield-fx.swift" -o "$HOME/bin/shield-fx" 2>/dev/null \
      && echo "    compiled shield-fx overlay" || true
  fi
fi

echo "==> 4/5  App configs"
# Leader Key — restore the real home path from the __HOME__ placeholder
LK_SRC="$REPO_ROOT/config/leader-key/config.json"
LK_DEST="$HOME/Library/Application Support/Leader Key/config.json"
if [[ -f "$LK_SRC" ]]; then
  mkdir -p "$(dirname "$LK_DEST")"
  if [[ -e "$LK_DEST" && ! -L "$LK_DEST" ]]; then cp "$LK_DEST" "$LK_DEST.bak.$(date +%s)"; fi
  sed "s|__HOME__|$HOME|g" "$LK_SRC" > "$LK_DEST"
  echo "    restored Leader Key config"
fi
# Karabiner — copy verbatim
KB_SRC="$REPO_ROOT/config/karabiner/karabiner.json"
if [[ -f "$KB_SRC" ]]; then
  backup_then_copy "$KB_SRC" "$HOME/.config/karabiner/karabiner.json"
  echo "    restored Karabiner config"
fi

# MachineSpirit Leader Key fork — the daily-driver launcher. Built from source
# (forks/LeaderKey) and auto-started by a self-healing LaunchAgent (relaunches
# on crash, respects a deliberate Quit). Needs full Xcode; if absent, stock
# Leader Key (from the Brewfile) stays the launcher.
FORK_DIR="$REPO_ROOT/forks/LeaderKey"
FORK_APP="$HOME/Applications/MachineSpirit Leader Key.app"
AGENT_SRC="$REPO_ROOT/config/leader-key/com.machinespirit.leader-key.plist"
AGENT_DEST="$HOME/Library/LaunchAgents/com.machinespirit.leader-key.plist"
AGENT_LABEL="com.machinespirit.leader-key"
if command -v xcodebuild >/dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
  echo "    building MachineSpirit Leader Key fork (Release)…"
  if xcodebuild -project "$FORK_DIR/Leader Key.xcodeproj" \
       -scheme "Leader Key" -configuration Release \
       -derivedDataPath "$FORK_DIR/DerivedData-Release" \
       -skipPackagePluginValidation -skipMacroValidation build \
       CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
       >/tmp/machinespirit-fork-build.log 2>&1; then
    mkdir -p "$HOME/Applications"
    rm -rf "$FORK_APP"
    ditto "$FORK_DIR/DerivedData-Release/Build/Products/Release/Leader Key.app" "$FORK_APP"
    mkdir -p "$(dirname "$AGENT_DEST")"
    sed "s|__HOME__|$HOME|g" "$AGENT_SRC" > "$AGENT_DEST"
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_DEST" || true
    echo "    installed fork + self-healing LaunchAgent (auto-starts at login)"
  else
    echo "    !! fork build failed (see /tmp/machinespirit-fork-build.log); stock Leader Key remains the launcher"
  fi
else
  echo "    (skipped) full Xcode not found — install it and re-run to build the fork; stock Leader Key is the launcher until then"
fi

echo "==> 5/5  macOS defaults (optional)"
read -r -p "    Apply macOS window/animation tweaks now? [y/N] " ans
if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
  bash "$REPO_ROOT/scripts/macos-defaults.sh"
fi

cat <<'EOF'

============================================================
  MANUAL STEPS (macOS won't let scripts grant these)
============================================================
  1. Karabiner-Elements: open it, approve Input Monitoring
     and the driver/system extension when prompted.
  2. System Settings > Privacy & Security > Accessibility:
     enable  MachineSpirit Leader Key, iTerm, and Rectangle
     (Rectangle prompts on first launch; also enable its
     "Launch on login").
  3. MachineSpirit Leader Key (the skull menu-bar icon): open
     Settings and set the activation shortcut to F19 (press
     Caps Lock). Auto-start is already handled by the
     self-healing LaunchAgent install.sh set up — do NOT also
     enable "Launch at login" (that would double-launch it).
  4. iTerm2: Settings > Profiles > Colors > Color Presets >
     Import  ->  config/iterm2/*.itermcolors, then select it.
  5. Menu bar: the skull icon IS the MachineSpirit menu —
     Leader Key + Rectangle + Karabiner controls in one place
     (their own icons are hidden by macos-defaults.sh +
     karabiner.json). On a crowded bar a new item lands in the
     hidden overflow; ⌘-drag the skull left of the clock once
     and macOS remembers the spot.
  6. tmux: brew installs it; `t t` launches a protected pane,
     `t m u x` opens the sheol recovery TUI. Nothing to wire.
  7. (Optional) To confirm before closing a pane running a live
     job: iTerm > Settings > Profiles > Session > "Prompt before
     closing" > "If there are jobs besides the login shell."
============================================================
EOF
echo "Done."
