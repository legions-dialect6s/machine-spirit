#!/bin/sh
# iterm-new-window.sh <command> [args…] — open a NEW iTerm2 window that runs the
# given command as its session program. Shared opener for the tmux launcher and
# the sheol TUI (both need a fresh interactive pane).
#
# The AppleScript body is guarded with try…on error…end try so an iTerm
# scripting hiccup fails silently instead of throwing a focus-stealing dialog at
# Leader Key (the crash-fix convention). The Leader Key bind also routes this
# through run-quiet.sh for belt-and-suspenders.
[ "$#" -eq 0 ] && exit 0
/usr/bin/osascript >/dev/null 2>&1 - "$@" <<'OSA'
on run argv
	set cmd to ""
	repeat with a in argv
		if cmd is "" then
			set cmd to quoted form of (contents of a)
		else
			set cmd to cmd & " " & quoted form of (contents of a)
		end if
	end repeat
	try
		tell application "iTerm2"
			activate
			create window with default profile command cmd
		end tell
	on error
		-- swallow: never block Leader Key with a dialog
	end try
end run
OSA
exit 0
