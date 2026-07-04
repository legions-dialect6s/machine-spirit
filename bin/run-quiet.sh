#!/bin/sh
# run-quiet.sh — run a command, swallow every failure, ALWAYS exit 0.
#
# Why this exists: Leader Key surfaces a focus-stealing macOS alert whenever a
# bound command fails (non-zero exit or an AppleScript error written to stderr).
# That alert often spawns behind other windows and blocks ALL further Leader Key
# input until it's dismissed. Routing an inline command through this wrapper
# guarantees Leader Key never sees a failure, so the dialog can never appear.
#
# Usage in a Leader Key command value:
#   ~/bin/run-quiet.sh osascript -e 'tell application "System Events" to keystroke "h" using command down'
#
# (Standalone bin/*.applescript files instead guard themselves with an internal
#  try…on error…end try — same goal, applied at the source.)
"$@" >/dev/null 2>&1
exit 0
