#!/bin/zsh
# Hold x after the tmux action: a fresh protected window, then spiral splits.
# Only the spawn path polls, for at most two seconds. Nothing runs while idle.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
HERE=${0:A:h}
state="${TMPDIR:-/tmp}/ms-tmux-hold"
umask 077
command -v tmux >/dev/null 2>&1 || exit 11
n=${MS_HOLD_N:-1}
[[ "$n" == <-> && "$n" -ge 1 ]] || exit 11

# Overlapping key presses must never split an older hold's session while the
# new window is opening. A miss is preferable to queuing surprise windows.
zmodload zsh/system || exit 11
[[ ! -L "$state.lock" ]] || exit 11
: >> "$state.lock" || exit 11
zsystem flock -t 0 -f lockfd "$state.lock" 2>/dev/null || exit 11
session=""
[[ -f "$state" && ! -L "$state" && -O "$state" ]] && IFS= read -r session < "$state"
if (( n == 1 )) || [[ -z "$session" ]] || ! tmux has-session -t "=$session" 2>/dev/null; then
  # A failed/timed-out spawn must never leave the previous hold as its target.
  print -r -- '' > "$state.$$" && mv -f "$state.$$" "$state" || exit 11
  session=$("$HERE/tmux-name.sh") || exit 11
  [[ -n "$session" ]] || exit 11
  "$HERE/tmux-launch.sh" "$session" >/dev/null 2>&1 &!
  # Publish atomically as soon as the session is visible. No idle polling.
  zmodload zsh/datetime
  deadline=$(( EPOCHREALTIME + 2.0 ))
  while (( EPOCHREALTIME < deadline )); do
    if tmux has-session -t "=$session" 2>/dev/null; then
      print -r -- "$session" > "$state.$$" && mv -f "$state.$$" "$state"
      exit $?
    fi
    sleep 0.04
  done
  exit 11
fi

# Pane IDs increase with creation, unlike indexes (which can be rearranged).
# Use the active tmux window, its oldest pane's cwd, and its newest pane.
rows=$(tmux list-panes -t "=$session:" -F $'#{pane_id}\x1f#{pane_current_path}' 2>/dev/null) || exit 11
oldest=2147483647 newest=-1 count=0 cwd=""
while IFS=$'\x1f' read -r pane dir; do
  [[ "$pane" == %<-> ]] || continue
  number=${pane#%}
  (( count++ ))
  if (( number < oldest )); then oldest=$number; cwd=$dir; fi
  (( number > newest )) && newest=$number
done <<< "$rows"
(( count > 0 )) || exit 11
direction=-h
(( n % 2 )) && direction=-v
tmux split-window "$direction" -t "%$newest" -c "$cwd" 2>/dev/null || exit 11
(( count++ ))
if (( count >= 5 )); then
  tmux select-layout -t "=$session:" tiled >/dev/null 2>&1 || exit 11
fi
if (( count == 3 )); then
  # Placement is asynchronous: AX latency must not hold up subsequent splits.
  ( "$HOME/bin/ms" win place max || true ) >/dev/null 2>&1 &!
fi
exit 0
