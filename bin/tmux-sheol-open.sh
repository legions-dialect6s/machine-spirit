#!/bin/sh
# tmux-sheol-open.sh — open sheol, but only ever ONE. Ends the previously-recorded
# sheol via its pidfile (surgical — a broad `pkill -f tmux-sheol.sh` could also
# hit an editor with the file open or a test process), then opens a fresh one.
# Bound to leader key  t m u x.
PIDFILE="$HOME/.cache/machine-spirit/sheol.pid"
if [ -f "$PIDFILE" ]; then
	oldpid=$(cat "$PIDFILE" 2>/dev/null)
	# only kill it if that PID is actually a sheol (guards PID reuse / stale file)
	if [ -n "$oldpid" ] && ps -p "$oldpid" -o command= 2>/dev/null | grep -q 'tmux-sheol\.sh'; then
		kill "$oldpid" 2>/dev/null
		i=0; while ps -p "$oldpid" >/dev/null 2>&1 && [ "$i" -lt 8 ]; do sleep 0.1; i=$((i+1)); done
		kill -9 "$oldpid" 2>/dev/null
	fi
	rm -f "$PIDFILE"
fi
exec "$HOME/bin/iterm-new-window.sh" "$HOME/bin/tmux-sheol.sh"
