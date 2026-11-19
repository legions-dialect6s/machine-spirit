#!/bin/zsh
# Photoshop's year-dependent name is irrelevant: resolve by bundle identifier.
# Frontmost -> next document (Ctrl-Tab); otherwise activate, including from cold.
# No background polling, dialogs or arbitrary typing if focus changes.
emulate -L zsh
result=$(/usr/bin/osascript 2>/dev/null <<'AS'
try
 with timeout of 2 seconds
  tell application "System Events"
   set psApps to application processes whose bundle identifier is "com.adobe.Photoshop"
   if (count of psApps) > 0 then
    set psApp to item 1 of psApps
    if frontmost of psApp then
     key code 48 using control down
     return "OK"
    end if
   end if
  end tell
  do shell script "/usr/bin/open -b com.adobe.Photoshop >/dev/null 2>&1"
  return "OK"
 end timeout
on error
 return "NONE"
end try
AS
) || exit 11
case $result in
 OK) exit 0 ;;
 DONE) exit 10 ;;
 *) exit 11 ;;
esac
