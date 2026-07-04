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
for f in "$REPO_ROOT"/bin/*; do
  cp "$f" "$HOME/bin/$(basename "$f")"
  echo "    installed bin/$(basename "$f")"
done

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
     enable  Leader Key, iTerm, and Rectangle  (Rectangle
     prompts on first launch; also enable its "Launch on login").
  3. Leader Key: set activation shortcut to F19 (press Caps
     Lock), and turn ON "Launch at login". Restart Leader Key
     so it reloads the restored config.
  4. iTerm2: Settings > Profiles > Colors > Color Presets >
     Import  ->  config/iterm2/*.itermcolors, then select it.
  5. Menu bar manager (Ice/Thaw): open it, drag rarely-used
     icons below the divider.
============================================================
EOF
echo "Done."
