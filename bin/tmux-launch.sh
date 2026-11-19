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
# An optional name lets tmux-hold track the exact session this launcher opens.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
name="${1:-$("$HERE/tmux-name.sh")}"
( "$HERE/terminals-core" reap >/dev/null 2>&1 & )
exec "$HERE/iterm-new-window.sh" "$HERE/tmux-session.sh" "$name"
