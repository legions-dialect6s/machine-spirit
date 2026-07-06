#!/bin/sh
# tmux-session.sh [session-name] — the program a "protected" iTerm pane runs.
#
# It (1) paints a visible TMUX badge on the pane, then (2) hands the pane to
# tmux — running INLINE in this one window (tmux's status bar along the bottom is
# the visible "this is protected" proof) — so the work outlives the window/pane
# being closed. `-A` attaches if a session with that name already exists, else
# creates it. Detach (leave it running) with tmux's  Ctrl-b d.
#
# (We deliberately do NOT use control mode `-CC`: it renders tmux windows as
# separate native iTerm windows and leaves a confusing "gateway" window behind —
# two windows per launch. Plain tmux = one window, one status bar, clear.)
#
# ── HARD CONSTRAINT (design around it, don't fight it) ────────────────────────
# You CANNOT adopt an already-running process into tmux. tmux has to be the
# PARENT from launch — there is no "wrap this existing shell/PID in tmux" path in
# tmux's model. So this only protects panes STARTED this way (the `t t` bind); an
# existing busy pane can't be retrofitted. For the accidental-close case on an
# unprotected busy pane, the busy-pane shield (pane-shield.py) is the guard.
name="${1:-ms-$$}"

if command -v tmux >/dev/null 2>&1; then
	printf '\033]1337;SetBadgeFormat=%s\007' "$(printf 'TMUX' | base64)"
	# Make it extra clear this pane is protected: put "tmux" on the right of the
	# status bar (the badge is unreliable under tmux, so the status bar is the
	# real "this is hardened" proof). `\;` chains the option-set onto the session.
	exec tmux new -A -s "$name" \; set-option status-right ' ⛧ tmux ⛧ '
else
	printf 'tmux is not installed — run:  brew install tmux\n'
	exec "${SHELL:-/bin/zsh}"
fi
