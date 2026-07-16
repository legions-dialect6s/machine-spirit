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

# Rectangle: hide its own menu-bar icon — its controls are folded into the
# MachineSpirit skull menu ("Rectangle — Windows" section). Window actions still
# fire via the rectangle:// scheme, so nothing is lost. Restart Rectangle after.
defaults write com.knollsoft.Rectangle hideMenubarIcon -bool true

echo "Done. Some changes require an app relaunch or logout to appear."
echo
echo "To revert everything this script did:"
echo "  defaults delete NSGlobalDomain NSWindowResizeTime"
echo "  defaults delete NSGlobalDomain NSAutomaticWindowAnimationsEnabled"
echo "  defaults delete com.knollsoft.Rectangle sizeOffset
  defaults delete com.knollsoft.Rectangle hideMenubarIcon"
