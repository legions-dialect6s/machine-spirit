#!/bin/zsh
# Hold collector. Unsupported browsers and failures produce a neutral pulse.
# A nonblocking per-domain lock prevents overlapping hold presses moving a tab twice.
emulate -L zsh
[[ $# -ge 1 && -n $1 && $# -le 2 ]] || exit 11
helper_dir=${0:A:h}
adapter=$(/usr/bin/osascript -l JavaScript "$helper_dir/web-browser.js" collector "$1" "${2:-}" 2>/dev/null) || exit 11
[[ $adapter == SAFARI ]] || exit 11
umask 077
base=${TMPDIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}
[[ -d $base ]] || exit 11
safe=${1//[^a-zA-Z0-9._-]/_}
# Include a checksum so different comma/punctuation combinations cannot alias state.
sum=$(print -rn -- "$1" | /usr/bin/cksum) || exit 11
state="${base%/}/ms-collect-${safe[1,100]}-${sum%% *}"
[[ ! -L $state && ! -L ${state}.lock ]] || exit 11
zmodload zsh/system 2>/dev/null || exit 11
: >> "${state}.lock" || exit 11
zsystem flock -t 0 -f lockfd "${state}.lock" 2>/dev/null || exit 11
result=$(/usr/bin/osascript "$helper_dir/web-collect.applescript" "$1" "${2:-}" "$state" "${MS_HOLD_N:-1}" 2>/dev/null) || exit 11
case $result in
  OK) exit 0 ;;
  DONE) exit 10 ;;
  *) exit 11 ;;
esac
