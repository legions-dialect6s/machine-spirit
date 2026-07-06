#!/usr/bin/env bash
# tmux-sheol.sh — SHEOL, the necromancer's ledger of tmux spirits.
#
# theme is load-bearing, used in earnest: a tmux session with a watcher walks
# THE LAND OF THE LIVING; a detached one is a restless spirit wandering SHEOL,
# the underworld, its work still alive, awaiting REVIVAL or BANISHMENT. bound to
# leader key  t m u x. only ever one sheol runs at a time (tmux-sheol-open.sh
# kills any old one first).
#
# two rosters, auto-refreshed (~REFRESH s poll) so spirits appear/vanish live:
#   ☀ THE LIVING   attached sessions (a client is watching)
#   ⌁ SHEOL        detached/orphaned sessions (no watcher; the work lives on)
#
# keys:
#   ↑/↓ or k/j   walk the ledger
#   r            REVIVE — reattach the spirit in a NEW window (fresh body)
#   c            COMMUNE — step INTO it in place to tend it without reviving;
#                the session's status bar shows the way back (Ctrl-b d), and
#                detaching returns you here
#   d d d        BANISH — destroy forever; press d thrice, the ◆ ward decaying
#   (⌘W or q closes the window)
#
# rendering: runs on the ALTERNATE screen with in-place redraw (cursor-home +
# clear-to-eol), so refreshes don't flicker the scrollbar or flash the screen,
# and quitting restores whatever was underneath.
#
# honest limits (see README): you CANNOT retrofit tmux onto a live process
# (necromancy only revives the tmux-born); tmux has no "detached-at" time
# (quiet-for = time since last activity); non-tmux "fragile" panes aren't listed
# yet (needs iTerm's API); refresh is a poll (macOS bash 3.2 -> integer read -t).

REFRESH=2

BOLD=$'\e[1m'; DIM=$'\e[2m'; INV=$'\e[7m'; RST=$'\e[0m'
GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; CYN=$'\e[36m'; MAG=$'\e[35m'

cleanup() { printf '\e[?25h\e[?1049l'; }        # show cursor, leave alt screen
trap cleanup EXIT INT TERM

have_tmux() { command -v tmux >/dev/null 2>&1; }

fmt_ago() {
	local now diff d h m
	now=$(date +%s); diff=$(( now - ${1:-$now} ))
	(( diff < 0 )) && diff=0
	d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
	if   (( d > 0 )); then printf '%dd%dh' "$d" "$h"
	elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
	else                   printf '%dm'    "$m"; fi
}

names=(); cmds=(); born=(); acts=(); state=(); first_dead=0; total=0
load() {
	names=(); cmds=(); born=(); acts=(); state=(); first_dead=0; total=0
	have_tmux || return 0
	local Ln=() Lc=() Lb=() La=() Dn=() Dc=() Db=() Da=()
	local n a c act cmd
	while IFS='|' read -r n a c act cmd; do
		[ -z "$n" ] && continue
		if [ "$a" != "0" ]; then Ln+=("$n"); Lc+=("${cmd:-?}"); Lb+=("$c"); La+=("$act")
		else                     Dn+=("$n"); Dc+=("${cmd:-?}"); Db+=("$c"); Da+=("$act"); fi
	done < <(tmux list-sessions -F \
		'#{session_name}|#{session_attached}|#{session_created}|#{session_activity}|#{pane_current_command}' \
		2>/dev/null)
	local i
	for i in "${!Ln[@]}"; do names+=("${Ln[$i]}"); cmds+=("${Lc[$i]}"); born+=("${Lb[$i]}"); acts+=("${La[$i]}"); state+=(1); done
	first_dead=${#names[@]}
	for i in "${!Dn[@]}"; do names+=("${Dn[$i]}"); cmds+=("${Dc[$i]}"); born+=("${Db[$i]}"); acts+=("${Da[$i]}"); state+=(0); done
	total=${#names[@]}
}

ward() {
	local a=$1 o='' i
	for i in 1 2 3; do if (( i <= a )); then o+="◆"; else o+="◇"; fi; done
	printf '%sBANISH %s  d ×%d more%s' "$RED" "$o" "$(( 3 - a ))" "$RST"
}

# print one row; every line ends with clear-to-eol so in-place redraw is clean
row() {
	local i=$1 kind=$2 quiet line wards=''
	if [ "$kind" = living ]; then quiet="active"; else quiet="$(fmt_ago "${acts[$i]}")"; fi
	line=$(printf '  %-20s %-12s %-7s %-8s' \
		"${names[$i]}" "${cmds[$i]:0:12}" "$(fmt_ago "${born[$i]}")" "$quiet")
	if (( i == sel && arm_sel == sel && arm > 0 )); then wards="   $(ward "$arm")"; fi
	if (( i == sel )); then printf '%s%s%s%s\e[K\n' "$INV" "$line" "$RST" "$wards"
	else                    printf '%s%s\e[K\n' "$line" "$wards"; fi
}

draw() {
	printf '\e[H'                                # cursor home; no full clear
	printf '  %s+++  S H E O L  +++%s  %sthe necromancer'\''s ledger of tmux spirits%s\e[K\n' \
		"$BOLD$MAG" "$RST" "$DIM" "$RST"
	printf '  %s↑/↓·k/j walk    r revive (new window)    c commune (peek)    d·d·d banish%s\e[K\n' "$DIM" "$RST"
	if ! have_tmux; then printf '\e[K\n  %stmux is not installed.%s  brew install tmux\e[K\n\e[J' "$YEL" "$RST"; return; fi
	if (( total == 0 )); then
		printf '\e[K\n  %sthe ledger is empty — no tmux spirits walk, living or dead.%s\e[K\n\e[J' "$DIM" "$RST"; return; fi
	printf '\e[K\n  %s☀ THE LIVING%s %s— a watcher is present%s\e[K\n' "$GRN$BOLD" "$RST" "$DIM" "$RST"
	(( first_dead == 0 )) && printf '     %s— none —%s\e[K\n' "$DIM" "$RST"
	local i
	for (( i=0; i<first_dead; i++ )); do row "$i" living; done
	printf '\e[K\n  %s⌁ SHEOL%s %s— detached spirits; restless, but the work lives%s\e[K\n' "$MAG$BOLD" "$RST" "$DIM" "$RST"
	(( first_dead == total )) && printf '     %s— none wander —%s\e[K\n' "$DIM" "$RST"
	for (( i=first_dead; i<total; i++ )); do row "$i" dead; done
	printf '\e[K\n  %s%d living · %d in sheol · auto-refreshing%s\e[K\n\e[J' \
		"$DIM" "$first_dead" "$(( total - first_dead ))" "$RST"
}

intro() {                                       # brief thematic reveal on open
	printf '\e[H\e[J'
	local t="+++  S H E O L  +++" i
	printf '\n\n\n              '
	for (( i=0; i<${#t}; i++ )); do printf '%s%s%s' "$BOLD$MAG" "${t:$i:1}" "$RST"; sleep 0.02; done
	sleep 0.18
}

move() { arm=0; arm_sel=-1; local n=$(( sel + $1 )); (( n >= 0 && n < total )) && sel=$n; }

revive() {
	(( total == 0 )) && return
	(( ${state[$sel]} == 1 )) && return          # already among the living
	"$HOME/bin/iterm-new-window.sh" tmux attach -t "${names[$sel]}"
	load                                         # update now, don't wait for the tick
}

commune() {
	(( total == 0 )) && return
	local n="${names[$sel]}"
	tmux set-option -t "$n" status-right " Ctrl-b d → back to sheol " 2>/dev/null
	tmux set-option -t "$n" status-right-length 32 2>/dev/null
	printf '\e[?25h\e[?1049l'                     # leave alt screen for the real session
	clear
	tmux attach -t "$n"                          # NOT exec — control returns here
	printf '\e[?1049h\e[?25l'                     # back into sheol's alt screen
	load
}

banish_step() {
	(( total == 0 )) && return
	if (( arm_sel != sel )); then arm=1; arm_sel=$sel; else (( arm++ )); fi
	if (( arm >= 3 )); then
		tmux kill-session -t "${names[$sel]}" 2>/dev/null
		arm=0; arm_sel=-1; load
		(( sel >= total )) && sel=$(( total > 0 ? total - 1 : 0 ))
	fi
}

sel=0; arm=0; arm_sel=-1
printf '\e[?1049h\e[?25l'                        # alt screen + hide cursor
intro
load
while :; do
	draw
	if ! IFS= read -rsn1 -t "$REFRESH" key; then
		arm=0; arm_sel=-1; load
		(( sel >= total )) && sel=$(( total > 0 ? total - 1 : 0 ))
		continue
	fi
	case "$key" in
		$'\e') rest=''; read -rsn2 -t 1 rest
			case "$rest" in '[A'|'OA') move -1 ;; '[B'|'OB') move 1 ;; esac ;;
		k|K) move -1 ;;
		j|J) move 1 ;;
		r|R) revive ;;
		c|C) commune ;;
		d|D) banish_step ;;
		q|Q) break ;;
	esac
done
