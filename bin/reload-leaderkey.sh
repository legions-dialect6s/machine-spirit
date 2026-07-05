#!/bin/sh
# reload-leaderkey.sh — restart Leader Key so config.json edits take effect.
#
# Leader Key reads ~/Library/Application Support/Leader Key/config.json at launch
# and does NOT reliably hot-reload it. After any edit to that file (by hand, by
# sync.sh, or by an agent/automation), the change stays STALE until Leader Key
# is restarted — which quietly confuses "I changed a bind and nothing happened".
# Run this to make edits go live immediately.
#
# Usage:  ~/bin/reload-leaderkey.sh
#
# (Longer term, the machine-spirit node-graph app owns Leader Key and reloads
#  automatically on every edit, so this manual step disappears.)

# Ask it to quit cleanly; fall back to a hard kill if it ignores us.
osascript -e 'tell application "Leader Key" to quit' >/dev/null 2>&1
i=0
while pgrep -x "Leader Key" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
	sleep 0.1
	i=$((i + 1))
done
pgrep -x "Leader Key" >/dev/null 2>&1 && killall "Leader Key" >/dev/null 2>&1

open -a "Leader Key"
echo "Leader Key reloaded — config is now live."
