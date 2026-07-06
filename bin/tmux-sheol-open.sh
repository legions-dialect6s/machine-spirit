#!/bin/sh
# tmux-sheol-open.sh — open sheol, but only ever ONE. Kills any existing sheol
# TUI first (its window closes with it), then opens a fresh one. Bound to
# leader key  t m u x.
#
# (kill-and-respawn keeps it dead simple and guarantees a single instance;
# sheol is a stateless live view, so nothing is lost. focus-the-existing-window
# instead of respawn is a nicer future refinement.)
pkill -f 'bin/tmux-sheol.sh' 2>/dev/null
sleep 0.15
exec "$HOME/bin/iterm-new-window.sh" "$HOME/bin/tmux-sheol.sh"
