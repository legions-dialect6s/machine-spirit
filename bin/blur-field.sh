#!/bin/zsh
# Messages: move typing into conversation search. Else, try AX focus on the
# focused window itself. No fallback keystrokes are sent into arbitrary fields.
emulate -L zsh
result=$(/usr/bin/osascript 2>/dev/null <<'AS'
try
 with timeout of 2 seconds
  tell application "System Events"
   set frontProcess to first application process whose frontmost is true
   tell frontProcess
    if bundle identifier is "com.apple.MobileSMS" then
     if not frontmost then return "NONE"
     keystroke "f" using command down
     return "OK"
    end if
    set focusedWindow to value of attribute "AXFocusedWindow"
    if focusedWindow is missing value then return "NONE"
    try
     if settable of attribute "AXFocused" of focusedWindow then set value of attribute "AXFocused" of focusedWindow to true
     if role of (value of attribute "AXFocusedUIElement") is "AXWindow" then return "OK"
    end try
    try
     if settable of attribute "AXFocusedUIElement" then set value of attribute "AXFocusedUIElement" to focusedWindow
     if role of (value of attribute "AXFocusedUIElement") is "AXWindow" then return "OK"
    end try
   end tell
  end tell
 end timeout
on error
 return "NONE"
end try
return "NONE"
AS
) || exit 11
case $result in
 OK) exit 0 ;;
 DONE) exit 10 ;;
 *) exit 11 ;;
esac
