#!/bin/sh
# tmux-launch.sh — open a NEW iTerm window whose shell runs inside tmux: a
# "protected" pane (one window, tmux status bar at the bottom) whose work
# survives the window/pane being closed. Bound to Leader Key  t t.
#
# Auto-generates a unique, evocative session name (two words, Halo-Monitor
# style — see tmux-name.sh) so every launch is a fresh protected session rather
# than reattaching a same-named one.
#
# See tmux-session.sh for the hard constraint (tmux must be the parent from
# launch — you can't retrofit a running process).
name="$("$HOME/bin/tmux-name.sh")"
exec "$HOME/bin/iterm-new-window.sh" "$HOME/bin/tmux-session.sh" "$name"
