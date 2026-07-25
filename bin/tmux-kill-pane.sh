#!/usr/bin/env bash
# machine-spirit: kill the tmux pane you're looking at.
#
# Bound to ⇪ t q q q q — a deliberate four-tap ward, because killing a pane ends
# a live process. It targets the *active pane* of the tmux session driving the
# frontmost iTerm session: the split you actually have focused. ⌘W already tears
# down a whole session/window; this is the finer, single-pane cut you'd
# otherwise open sheol or the menu bar to make.
#
# Safe no-op if the front terminal isn't a tmux client (a plain shell, a
# browser, the splash window, …): it kills nothing it can't positively identify.
set -euo pipefail

# The tty backing the frontmost iTerm session is the tmux client's tty.
tty=$(osascript -e 'tell application "iTerm2" to tell current session of current window to get tty' 2>/dev/null) || exit 0
[ -n "${tty:-}" ] || exit 0

# tty -> the tmux session that client is driving (empty if it isn't tmux).
session=$(tmux list-clients -F '#{client_tty}|#{client_session}' 2>/dev/null \
  | awk -F'|' -v t="$tty" '$1 == t { print $2; exit }')
[ -n "${session:-}" ] || exit 0

# The active pane of that session's current window = the one selected on screen.
pane=$(tmux list-panes -t "=${session}" -F '#{pane_active} #{pane_id}' 2>/dev/null \
  | awk '$1 == 1 { print $2; exit }')
[ -n "${pane:-}" ] || exit 0

# Kill just that pane. tmux collapses the window/session if it was the last one.
tmux kill-pane -t "${pane}" 2>/dev/null || true
