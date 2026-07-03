#!/usr/bin/env bash
# sync.sh — pull the CURRENT live configuration off this machine INTO the repo.
#
# Run this now (once) to capture your working setup, and again any time you
# change a keybind, remap, or script. Then commit + push.
#
# Absolute home paths (e.g. inside Leader Key's config) are rewritten to the
# placeholder __HOME__ so the repo stays portable and doesn't leak your username.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEADER_LIVE="$HOME/Library/Application Support/Leader Key/config.json"
KARABINER_LIVE="$HOME/.config/karabiner/karabiner.json"
BIN_LIVE="$HOME/bin"

echo "==> Syncing live config into repo at: $REPO_ROOT"

# Leader Key — template out the home path
if [[ -f "$LEADER_LIVE" ]]; then
  sed "s|$HOME|__HOME__|g" "$LEADER_LIVE" > "$REPO_ROOT/config/leader-key/config.json"
  echo "  captured Leader Key config"
else
  echo "  (skipped) Leader Key config not found at $LEADER_LIVE"
fi

# Karabiner — no home paths inside, copy verbatim
if [[ -f "$KARABINER_LIVE" ]]; then
  cp "$KARABINER_LIVE" "$REPO_ROOT/config/karabiner/karabiner.json"
  echo "  captured Karabiner config"
else
  echo "  (skipped) Karabiner config not found at $KARABINER_LIVE"
fi

# ~/bin scripts — copy any that live in the repo's bin/ back from the live dir
if [[ -d "$BIN_LIVE" ]]; then
  for f in "$REPO_ROOT"/bin/*; do
    name="$(basename "$f")"
    if [[ -f "$BIN_LIVE/$name" ]]; then
      cp "$BIN_LIVE/$name" "$REPO_ROOT/bin/$name"
      echo "  captured bin/$name"
    fi
  done
fi

echo "==> Done. Review changes with:  git -C \"$REPO_ROOT\" diff"
echo "    Then commit + push."
