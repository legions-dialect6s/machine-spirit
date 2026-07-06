#!/bin/sh
# tmux-split.sh — split the CURRENT iTerm pane and run a tmux-protected shell in
# the new pane (a protected pane right beside where you are). Bound to  t d.
#
# NOTE: this makes a NEW tmux session in an iTerm split. If you're already inside
# a tmux session and want a tmux split of THAT session, use tmux's own
# Ctrl-b " (horizontal) / Ctrl-b % (vertical) instead.
#
# AppleScript guarded with try/on error so it never dialogs at Leader Key.
name="msd-$(date +%H%M%S)"
sess="$HOME/bin/tmux-session.sh"
/usr/bin/osascript >/dev/null 2>&1 <<OSA
try
	tell application "iTerm2"
		tell current session of current window
			split horizontally with default profile command "$sess $name"
		end tell
	end tell
on error
end try
OSA
exit 0
