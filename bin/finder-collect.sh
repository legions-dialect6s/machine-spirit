#!/bin/zsh
# Gather one Finder folder tab per press; OK/DONE/NONE -> 0/10/11, no dialogs.
# Probed on Darwin 25.3: adding a tab changed Finder's window count 9 -> 10,
# but AX physical windows stayed 9. Therefore NEVER enumerate Finder windows
# as separate containers. Raise AX window 2 to select a tab outside the collector.
# Store the new selected tab ID after each move, retaining the same physical window.
# Create/verify the destination BEFORE closing the source, to survive AX failures.
emulate -L zsh
umask 077
base=${TMPDIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}
[[ -d $base ]] || exit 11
state="${base%/}/ms-finder-collect"
[[ ! -L $state && ! -L ${state}.lock ]] || exit 11
zmodload zsh/system 2>/dev/null || exit 11
: >> "${state}.lock" || exit 11
zsystem flock -t 0 -f lockfd "${state}.lock" 2>/dev/null || exit 11
result=$(/usr/bin/osascript - "$state" "${MS_HOLD_N:-1}" 2>/dev/null <<'AS'
on run argv
 try
  with timeout of 2 seconds
   set statePath to item 1 of argv
   set collectorID to 0
   tell application "Finder"
    if (count of Finder windows) = 0 then return "NONE"
   end tell
   if item 2 of argv is not "1" then
    try
     set collectorID to (read POSIX file statePath) as integer
    end try
   end if
   tell application "Finder"
    if not (exists Finder window id collectorID) then set collectorID to id of front Finder window
   end tell
   my saveID(statePath, collectorID)
   if not my raiseTab(collectorID) then return "NONE"
   tell application "System Events" to tell process "Finder"
    if (count of windows) < 2 then return "NONE"
    perform action "AXRaise" of window 2
   end tell
   set sourceID to collectorID
   repeat 10 times
    tell application "Finder" to set sourceID to id of front Finder window
    if sourceID is not collectorID then exit repeat
    delay 0.02
   end repeat
   if sourceID = collectorID then return "NONE"
   tell application "Finder"
    set folderTarget to target of Finder window id sourceID as alias
    set beforeIDs to id of every Finder window
   end tell
   if not my raiseTab(collectorID) then return "NONE"
   tell application "System Events" to tell process "Finder"
    set physicalCount to count of windows
    keystroke "t" using command down
   end tell
   set newID to 0
   repeat 25 times
    tell application "Finder"
     -- Refresh the full list: repeated front-window queries can stay stale
     -- during Finder's asynchronous tab creation on Darwin 25.
     set currentIDs to id of every Finder window
     set candidateID to id of front Finder window
    end tell
    if beforeIDs does not contain candidateID then
     set newID to candidateID
     exit repeat
    end if
    delay 0.02
   end repeat
   if newID = 0 then return "NONE"
   -- If Cmd-T unexpectedly created a physical window, preserve the source.
   tell application "System Events" to tell process "Finder" to set afterCount to count of windows
   if afterCount is not physicalCount then
    tell application "Finder" to close Finder window id newID
    return "NONE"
   end if
   try
    tell application "Finder"
     set target of Finder window id newID to folderTarget
     if (target of Finder window id newID as alias) is not folderTarget then error "Target not set"
    end tell
    my saveID(statePath, newID)
   on error
    tell application "Finder" to close Finder window id newID
    return "NONE"
   end try
   tell application "Finder" to close Finder window id sourceID
   -- Closing the last source tab updates AX asynchronously.
   repeat 5 times
    tell application "System Events" to tell process "Finder" to set remaining to count of windows
    if remaining < physicalCount then exit repeat
    delay 0.02
   end repeat
   if remaining = 1 then return "DONE"
   return "OK"
  end timeout
 on error
  return "NONE"
 end try
end run
on raiseTab(wid)
 tell application "Finder"
  activate
  set index of Finder window id wid to 1
 end tell
 repeat 10 times
  tell application "Finder" to set frontID to id of front Finder window
  if frontID = wid then
   tell application "System Events" to tell process "Finder"
    if frontmost then return true
   end tell
  end if
  delay 0.02
 end repeat
 return false
end raiseTab
on saveID(statePath, wid)
 set f to open for access POSIX file statePath with write permission
 try
  set eof f to 0
  write (wid as text) to f
  close access f
 on error errText number errNum
  try
   close access f
  end try
  error errText number errNum
 end try
end saveID
AS
) || exit 11
case $result in
 OK) exit 0 ;;
 DONE) exit 10 ;;
 *) exit 11 ;;
esac
