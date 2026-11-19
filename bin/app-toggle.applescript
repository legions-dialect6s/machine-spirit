use framework "AppKit"
use scripting additions
-- app-toggle.sh <App Name> [--close quit|windows]. Internal argv also includes
-- the sibling FaceTime helper. Resolve apps through NSWorkspace, then use PID
-- for AX so localized/process names need not equal the requested application.
-- AppKit mouse coordinates are flipped using the PRIMARY screen's top edge,
-- not the active screen: this handles monitors above/left of the main display.
-- Poll only after launch (100 ms, at most 3 s). No work occurs while idle.
-- Failures are silent; TextEdit's intentional native save prompt is preserved.
on run argv
 try
  set appName to item 1 of argv
  set closeMode to item 2 of argv
  if closeMode is not in {"quit", "windows"} then return "NONE"
  set ws to current application's NSWorkspace's sharedWorkspace()
  set frontApp to ws's frontmostApplication()
  if appName = "FaceTime" and (frontApp's bundleIdentifier() as text) = "com.apple.MobileSMS" then
   return do shell script "/usr/bin/osascript " & quoted form of item 3 of argv & " 2>/dev/null"
  end if
  set appPath to ws's fullPathForApplication:appName
  if appPath is missing value then return "NONE"
  set bundleID to (current application's NSBundle's bundleWithPath:appPath)'s bundleIdentifier()
  set apps to current application's NSRunningApplication's runningApplicationsWithBundleIdentifier:bundleID
  if (apps's |count|()) = 0 then
   do shell script "/usr/bin/open -a " & quoted form of appName & " >/dev/null 2>&1"
   set deadline to (current application's NSDate's timeIntervalSinceReferenceDate()) + 3
   repeat 30 times
    delay 0.1
    set apps to current application's NSRunningApplication's runningApplicationsWithBundleIdentifier:bundleID
    if (apps's |count|()) > 0 then
     set pid to ((apps's firstObject())'s processIdentifier()) as integer
     set windowReady to false
     set stillFront to false
     try
      with timeout of 1 second
       tell application "System Events"
        set targetProcess to first application process whose unix id is pid
        set windowReady to (count of windows of targetProcess) > 0
        set stillFront to frontmost of targetProcess
       end tell
      end timeout
     end try
     if windowReady then
      -- Never place a different app if the user switched during launch.
      if stillFront then
       try
        do shell script "\"$HOME/bin/ms\" win place smart >/dev/null 2>&1 || true"
       end try
      end if
      return "OK"
     end if
    end if
    if (current application's NSDate's timeIntervalSinceReferenceDate()) >= deadline then exit repeat
   end repeat
   return "OK"
  end if
  set runningApp to apps's firstObject()
  set pid to runningApp's processIdentifier() as integer
  set wasFront to runningApp's isActive() as boolean
  set wasHidden to runningApp's isHidden() as boolean
  with timeout of 2 seconds
   if not wasFront or wasHidden then
    runningApp's unhide()
    tell application "System Events" to tell (first application process whose unix id is pid)
     repeat with w in windows
      try
       if value of attribute "AXMinimized" of w then set value of attribute "AXMinimized" of w to false
      end try
     end repeat
    end tell
    runningApp's activateWithOptions:(current application's NSApplicationActivateIgnoringOtherApps)
    return "OK"
   end if
   set mousePoint to current application's NSEvent's mouseLocation()
   set primaryFrame to (current application's NSScreen's screens()'s firstObject())'s frame()
   set mouseX to mousePoint's x
   set mouseY to ((item 2 of item 1 of primaryFrame) + (item 2 of item 2 of primaryFrame)) - (mousePoint's y)
   set overWindow to false
   tell application "System Events" to tell (first application process whose unix id is pid)
    repeat with w in windows
     -- Some apps expose transient AX windows without geometry/minimized state.
     try
      set minimized to false
      try
       if (value of attribute "AXMinimized" of w) is true then set minimized to true
      end try
      if not minimized then
       set {wx, wy} to position of w
       set {ww, wh} to size of w
       if mouseX >= wx and mouseX < wx + ww and mouseY >= wy and mouseY < wy + wh then set overWindow to true
      end if
     end try
    end repeat
    if not overWindow then
     if (count of windows) = 0 then return "NONE"
     if not frontmost then return "NONE"
     keystroke "`" using command down
     -- Cmd-` raises the next window itself; do not race it by re-raising window 1.
     return "OK"
    end if
   end tell
  end timeout
  -- Keep user-facing save confirmations outside the short AX timeout.
  if (bundleID as text) = "com.apple.TextEdit" then
   tell application "TextEdit"
    close every document saving ask
    if closeMode = "quit" and (count of documents) = 0 then quit
   end tell
  else if closeMode = "quit" then
   tell application appName to quit
  else
   with timeout of 2 seconds
    tell application "System Events" to tell (first application process whose unix id is pid)
     if not frontmost then return "NONE"
     set windowList to windows
     set closedCount to 0
     repeat with w in windowList
      try
       set closeButton to value of attribute "AXCloseButton" of w
       if enabled of closeButton then
        click closeButton
        set closedCount to closedCount + 1
       end if
      end try
     end repeat
     if closedCount = 0 then return "NONE"
    end tell
   end timeout
  end if
  return "OK"
 on error
  return "NONE"
 end try
end run
