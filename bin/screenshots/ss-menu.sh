#!/bin/bash
# Open the macOS screenshot/recording menu (same as pressing Cmd+Shift+5).
# NOTE: the app running this script (Leader Key / your terminal) needs
# Accessibility permission in System Settings > Privacy & Security.
osascript -e 'tell application "System Events" to keystroke "5" using {command down, shift down}'
