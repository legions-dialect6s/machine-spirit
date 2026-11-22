#!/bin/zsh
# Open or restore a utility, then close it when invoked while frontmost. Native unsaved
# document confirmation is deliberately retained (especially for TextEdit).
emulate -L zsh
[[ $# -eq 1 || ( $# -eq 3 && $2 == --close && ( $3 == quit || $3 == windows ) ) ]] || exit 11
[[ -n $1 ]] || exit 11
result=$(/usr/bin/osascript "${0:A:h}/app-toggle.applescript" "$1" "${3:-quit}" "${0:A:h}/facetime-selected.applescript" 2>/dev/null) || exit 11
case $result in
 OK) exit 0 ;;
 DONE) exit 10 ;;
 *) exit 11 ;;
esac
