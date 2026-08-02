#!/usr/bin/env bash
# tmux-sheol.sh — SHEOL, the necromancer's ledger of tmux spirits.
#
# theme is load-bearing: a tmux session with a watcher walks THE LAND OF THE
# LIVING; a detached one is a restless spirit wandering SHEOL, the underworld,
# its work still alive. bound to leader key  t m u x  (only ever one runs).
#
# keys:
#   ↑/↓ or k/j   walk the ledger
#   r            REVIVE — reattach the spirit in a NEW window (fresh body)
#   c            COMMUNE — step INTO it in place to tend it; status bar shows the
#                way back (Ctrl-b d), detaching returns you here
#   d d d        BANISH — press d thrice, the ◆ ward decaying:
#                  · a LIVING spirit is detached -> sent to sheol
#                  · a spirit already in SHEOL is killed -> exiled forever
#   (⌘W or q closes the window)
#
# performance + safety notes (learned the hard way):
#   * runs on the ALTERNATE screen with in-place redraw, and ONLY redraws when
#     the roster/selection actually changes — an idle ledger costs ~nothing (no
#     per-tick WindowServer churn).
#   * the INT/TERM trap EXITS (so `pkill` can end it and single-instance works);
#     a bare cleanup trap that doesn't exit would swallow the signal and pile up.
#   * a lost stdin returns EOF, not a timeout -> we break instead of busy-looping.
#   * macOS bash 3.2 rejects fractional read -t, so all timeouts are integers.
#
# honest limits (see README): can't retrofit tmux onto a live process; tmux has
# no "detached-at" time (quiet-for = time since last activity); non-tmux
# "fragile" panes + the dock nag are deferred to the app.

# ── PATH bootstrap ────────────────────────────────────────────────────────────
# iTerm launches this as a custom-command session (see iterm-new-window.sh), which
# does NOT start a login shell — so ~/.zprofile's `brew shellenv` never runs and
# Homebrew (hence tmux) is missing from PATH after a fresh GUI/boot launch of iTerm.
# Re-establish it here so have_tmux and every tmux/sheol-core call below can find it.
# Portable: tries Apple-Silicon then Intel brew prefixes; no-op when tmux is already
# on PATH (a login-shell parent). Exported so sheol-core inherits it.
if ! command -v tmux >/dev/null 2>&1; then
	for _b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
		[ -x "$_b" ] && eval "$("$_b" shellenv)" && break
	done
	unset _b
fi

REFRESH=1        # poll interval; redraw only fires when something actually changed
PIDFILE="$HOME/.cache/machine-spirit/sheol.pid"   # single-instance marker
# All tmux operations go through sheol-core (shared with MachineSpirit.app) —
# resolved beside this script so the pair works from ~/bin and from the repo.
CORE="$(cd "$(dirname "$0")" && pwd)/sheol-core"
LAUNCHER="$(cd "$(dirname "$0")" && pwd)/tmux-launch.sh"   # n: a new living spirit

BOLD=$'\e[1m'; DIM=$'\e[2m'; INV=$'\e[7m'; RST=$'\e[0m'
GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; CYN=$'\e[36m'; MAG=$'\e[35m'

cleanup() { printf '\e[?25h\e[?1049l'; rm -f "$PIDFILE"; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM        # MUST exit, or pkill can't kill us

have_tmux() { command -v tmux >/dev/null 2>&1; }

fmt_ago() {
	local now diff d h m
	now=${_NOW:-$(date +%s)}; diff=$(( now - ${1:-$now} ))
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
	# Unit-separator (\x1f) delimiter — safe vs a session name/command containing
	# a literal '|', which would otherwise garble the parse/display.
	local n a c act cmd US=$'\x1f'
	while IFS="$US" read -r n a c act cmd; do
		[ -z "$n" ] && continue
		if [ "$a" != "0" ]; then Ln+=("$n"); Lc+=("${cmd:-?}"); Lb+=("$c"); La+=("$act")
		else                     Dn+=("$n"); Dc+=("${cmd:-?}"); Db+=("$c"); Da+=("$act"); fi
	done < <("$CORE" list)
	local i
	for i in "${!Ln[@]}"; do names+=("${Ln[$i]}"); cmds+=("${Lc[$i]}"); born+=("${Lb[$i]}"); acts+=("${La[$i]}"); state+=(1); done
	first_dead=${#names[@]}
	for i in "${!Dn[@]}"; do names+=("${Dn[$i]}"); cmds+=("${Dc[$i]}"); born+=("${Db[$i]}"); acts+=("${Da[$i]}"); state+=(0); done
	total=${#names[@]}
	last_save=$("$CORE" last-save 2>/dev/null || echo 0)   # newest snapshot epoch, for the footer
}

sig() {
	# capture everything VISIBLE so any real change (session added/removed,
	# attach<->detach, the running command changing, a minute ticking on
	# born/quiet-for) triggers a redraw — but nothing that would churn every tick
	# (times are minute-bucketed via fmt_ago, not raw epochs). Joints are the
	# same \x1f unit separator the parse uses — a name carrying '|' or ':'
	# must not alias two different rosters into one signature (missed redraw).
	_NOW=$(date +%s)                        # one clock read per signature, not per row
	local US=$'\x1f'
	local s="$total$US$first_dead$US$sel$US$arm$US$arm_sel$US$mash$US$last_save" i
	for (( i=0; i<total; i++ )); do
		s+="$US${names[$i]}$US${cmds[$i]}$US${state[$i]}$US$(fmt_ago "${born[$i]}")$US$(fmt_ago "${acts[$i]}")"
	done
	printf '%s' "$s"
}

ward() {   # $1 = arm, $2 = 1 living (→sheol) / 0 dead (→exile)
	local a=$1 o='' i where
	for i in 1 2 3; do if (( i <= a )); then o+="◆"; else o+="◇"; fi; done
	if (( $2 == 1 )); then where="→ sheol"; else where="→ exile"; fi
	printf '%sBANISH %s %s  d ×%d%s' "$RED" "$o" "$where" "$(( 3 - a ))" "$RST"
}

# the nuke's 10-pip draining ward: pips left = 10 - taps; fires at empty.
mass_ward() {
	local o='' i
	for (( i=0; i<10; i++ )); do if (( i < 10 - mash )); then o+="◆"; else o+="◇"; fi; done
	if (( mash > 0 )); then printf '%s%s☠ BANISH ALL  %s  q ×%d more%s' "$BOLD" "$RED" "$o" "$(( 10 - mash ))" "$RST"
	else                    printf '%s%s☠ BANISH ALL  %s  mash q ×10%s'  "$BOLD" "$RED" "$o" "$RST"; fi
}

row() {
	local i=$1 kind=$2 quiet line wards=''
	if [ "$kind" = living ]; then quiet="active"; else quiet="$(fmt_ago "${acts[$i]}")"; fi
	line=$(printf '  %-20s %-12s %-7s %-8s' \
		"${names[$i]}" "${cmds[$i]:0:12}" "$(fmt_ago "${born[$i]}")" "$quiet")
	if (( i == sel && arm_sel == sel && arm > 0 )); then wards="   $(ward "$arm" "${state[$i]}")"; fi
	if (( i == sel )); then printf '%s%s%s%s\e[K\n' "$INV" "$line" "$RST" "$wards"
	else                    printf '%s%s\e[K\n' "$line" "$wards"; fi
}

draw() {
	_NOW=$(date +%s)                        # one clock read per redraw, not per row
	printf '\e[H'
	printf '  %s+++  S H E O L  +++%s  %sthe necromancer'\''s ledger of tmux spirits%s\e[K\n' \
		"$BOLD$MAG" "$RST" "$DIM" "$RST"
	printf '  %s↑/↓ walk · r revive · c commune · n new · d·d·d banish · s save · R restore%s\e[K\n' "$DIM" "$RST"
	if ! have_tmux; then printf '\e[K\n  %stmux is not installed.%s  brew install tmux\e[K\n\e[J' "$YEL" "$RST"; return; fi
	if (( total == 0 )); then
		printf '\e[K\n  %s%s%s\e[K\n' "$DIM" "${msg:-the ledger is empty — no tmux spirits walk, living or dead.}" "$RST"
		if (( last_save > 0 )); then printf '\e[K\n  %s♻ last snapshot %s ago — press R to restore%s\e[K\n\e[J' "$CYN" "$(fmt_ago "$last_save")" "$RST"
		else                         printf '\e[K\n  %sno snapshot saved yet — press s to save one%s\e[K\n\e[J' "$DIM" "$RST"; fi
		return; fi
	printf '\e[K\n  %s☀ THE LIVING%s %s— a watcher is present%s\e[K\n' "$GRN$BOLD" "$RST" "$DIM" "$RST"
	(( first_dead == 0 )) && printf '     %s— none —%s\e[K\n' "$DIM" "$RST"
	local i
	for (( i=0; i<first_dead; i++ )); do row "$i" living; done
	printf '\e[K\n  %s⌁ SHEOL%s %s— detached spirits; restless, but the work lives%s\e[K\n' "$MAG$BOLD" "$RST" "$DIM" "$RST"
	(( first_dead == total )) && printf '     %s— none wander —%s\e[K\n' "$DIM" "$RST"
	for (( i=first_dead; i<total; i++ )); do row "$i" dead; done
	# ☠ BANISH ALL — the nuke row (index == total); selectable, mash q ×10 to fire
	printf '\e[K\n'
	if (( sel == total )); then printf '  %s%s%s\e[K\n' "$INV" "$(mass_ward)" "$RST"
	else                        printf '  %s%s☠ BANISH ALL%s  %s(↓ to select · mash q ×10)%s\e[K\n' "$DIM" "$RED" "$RST" "$DIM" "$RST"; fi
	# footer: counts · last snapshot age · transient message (💾/♻/☠)
	local saved
	if (( last_save > 0 )); then saved="saved $(fmt_ago "$last_save") ago"; else saved="never saved"; fi
	printf '\e[K\n  %s%d living · %d in sheol · %s%s%s\e[K\n\e[J' \
		"$DIM" "$first_dead" "$(( total - first_dead ))" "$saved" "${msg:+   $CYN$msg$DIM}" "$RST"
}

intro() {
	printf '\e[H\e[J'
	local t="+++  S H E O L  +++" i
	printf '\n\n\n              '
	for (( i=0; i<${#t}; i++ )); do printf '%s%s%s' "$BOLD$MAG" "${t:$i:1}" "$RST"; sleep 0.02; done
	sleep 0.18
}

# sel ranges 0..total: indices 0..total-1 are spirits, index == total is the
# ☠ BANISH-ALL row (only present when total>0). Moving resets both wards.
move() { arm=0; arm_sel=-1; mash=0; local n=$(( sel + $1 )); (( n >= 0 && n <= total && total > 0 )) && sel=$n; }

# ── resurrect: save / restore the whole server (see ~/.tmux.conf) ──────────────
do_save()    { "$CORE" save;    msg="💾 layout saved";              load; }
do_restore() { "$CORE" restore; msg="♻ restored from last snapshot"; load; sel=0; }

# ── BANISH ALL: the nuke. Guarded by a 10-tap draining ward (q on the ☠ row);
# kill-all SAVES a snapshot first, so even this is recoverable with R. ──────────
mass_step() {
	(( total == 0 || sel >= total )) && return   # no-op on the ☠ BANISH-ALL row
	(( mash++ )); arm_at=$SECONDS
	if (( mash >= 10 )); then
		"$CORE" kill-all          # snapshot, then kill the server → all spirits gone
		mash=0; sel=0
		msg="☠ all spirits banished — press R to restore them"
		load
	fi
}

revive() {
	(( total == 0 || sel >= total )) && return   # no-op on the ☠ BANISH-ALL row
	(( ${state[$sel]} == 1 )) && return
	"$CORE" revive "${names[$sel]}"
	load
}

commune() {
	(( total == 0 || sel >= total )) && return   # no-op on the ☠ BANISH-ALL row
	local n="${names[$sel]}"
	tmux set-option -t "$n" status-right " Ctrl-b d → back to sheol " 2>/dev/null
	tmux set-option -t "$n" status-right-length 32 2>/dev/null
	printf '\e[?25h\e[?1049l'; clear
	tmux attach -t "$n"
	printf '\e[?1049h\e[?25l'
	load
}

banish_step() {
	(( total == 0 || sel >= total )) && return   # no-op on the ☠ BANISH-ALL row
	if (( arm_sel != sel )); then arm=1; arm_sel=$sel; else (( arm++ )); fi
	arm_at=$SECONDS
	if (( arm >= 3 )); then
		if (( ${state[$sel]} == 1 )); then
			"$CORE" detach "${names[$sel]}"   # living -> sheol
		else
			"$CORE" kill "${names[$sel]}"     # dead -> exiled
		fi
		arm=0; arm_sel=-1; load
		(( sel >= total )) && sel=$(( total > 0 ? total - 1 : 0 ))
	fi
}

sel=0; arm=0; arm_sel=-1; arm_at=0; mash=0; msg=''; last_save=0
mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null; printf '%s\n' "$$" > "$PIDFILE"
printf '\e[?1049h\e[?25l'
intro
load
draw
sig=$(sig)
while :; do
	# bash 3.2 returns 1 for BOTH read timeout AND EOF, so we can't tell them
	# apart by return code. Distinguish by the tty: a live terminal -> it was a
	# timeout (refresh); a closed stdin -> real EOF (exit, don't busy-loop).
	if ! IFS= read -rsn1 -t "$REFRESH" key; then
		[ -t 0 ] || break                   # stdin gone -> exit
		(( arm > 0 && SECONDS - arm_at >= 2 )) && { arm=0; arm_sel=-1; }  # single-banish ward decays
		(( mash > 0 && SECONDS - arm_at >= 2 )) && mash=0                 # mass-banish ward refills
		load                                # tty timeout -> refresh roster
		(( sel > total )) && sel=$(( total > 0 ? total : 0 ))            # keep sel in range (total == ☠ row)
		new=$(sig); [ "$new" != "$sig" ] && { draw; sig=$new; }   # redraw only if changed
		continue
	fi
	msg=''                                      # any keypress dismisses the last toast
	case "$key" in
		$'\e') rest=''; read -rsn2 -t 1 rest
			case "$rest" in '[A'|'OA') move -1 ;; '[B'|'OB') move 1 ;; esac ;;
		k|K) move -1 ;;
		j|J) move 1 ;;
		r) revive ;;
		R) do_restore ;;
		c|C) commune ;;
		n|N) "$LAUNCHER" >/dev/null 2>&1; load ;;   # birth a spirit in the land of the living
		d|D) banish_step ;;
		s|S) do_save ;;
		# on the ☠ row, q drains the nuke ward; anywhere else q quits. Q always quits.
		q) if (( total > 0 && sel == total )); then mass_step; else break; fi ;;
		Q) break ;;
	esac
	draw; sig=$(sig)
done
