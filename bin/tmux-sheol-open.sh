#!/bin/sh
# tmux-sheol-open.sh — open sheol, but only ever ONE. Kills any existing sheol
# TUI first (now that sheol's trap exits on SIGTERM, pkill actually ends it and
# its window closes), then opens a fresh one. Bound to leader key  t m u x.
pkill -f 'bin/tmux-sheol.sh' 2>/dev/null
i=0
while pgrep -f 'bin/tmux-sheol.sh' >/dev/null 2>&1 && [ "$i" -lt 8 ]; do sleep 0.1; i=$((i+1)); done
pkill -9 -f 'bin/tmux-sheol.sh' 2>/dev/null      # belt-and-suspenders
exec "$HOME/bin/iterm-new-window.sh" "$HOME/bin/tmux-sheol.sh"
