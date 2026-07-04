#!/usr/bin/env bash
# macos-defaults.sh — user-level macOS tweaks for snappier window behavior.
# All settings here are safe, reversible, and require no sudo.
# They take full effect after apps relaunch / next login.
set -euo pipefail

echo "Applying macOS window/animation tweaks..."

# Near-instant window resize (default is ~0.2s)
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001

# Disable automatic window open/close animations
defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false

# Rectangle: bigger step for its native larger/smaller actions (default 30px)
defaults write com.knollsoft.Rectangle sizeOffset -int 100

echo "Done. Some changes require an app relaunch or logout to appear."
echo
echo "To revert everything this script did:"
echo "  defaults delete NSGlobalDomain NSWindowResizeTime"
echo "  defaults delete NSGlobalDomain NSAutomaticWindowAnimationsEnabled"
echo "  defaults delete com.knollsoft.Rectangle sizeOffset"
