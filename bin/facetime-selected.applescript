-- Start VIDEO FaceTime for the conversation selected in frontmost Messages.
-- Probed Darwin 25.3: Conversation has exact items "FaceTime Video" and
-- "FaceTime Audio". Prefer the video item; never select audio/call alternatives.
-- Toolbar fallback only accepts an explicitly video-labelled FaceTime button.
-- This initiates a real call when invoked; tests inspect availability, not click.
-- Missing/disabled UI, permissions and errors return NONE without dialogs.
on run argv
 try
  with timeout of 2 seconds
   tell application "System Events"
    if not (exists process "Messages") then return "NONE"
    tell process "Messages"
     if not frontmost then return "NONE"
     try
      set videoItem to menu item "FaceTime Video" of menu 1 of menu bar item "Conversation" of menu bar 1
      if enabled of videoItem then
       click videoItem
       return "OK"
      end if
     end try
     if (count of windows) = 0 then return "NONE"
     -- Scan only toolbar controls, not conversation text or contact information.
     repeat with bar in toolbars of window 1
      repeat with b in buttons of bar
       set labelText to ""
       try
        set labelText to (name of b) as text
       end try
       try
        set labelText to labelText & " " & (description of b as text)
       end try
       if labelText contains "FaceTime" and labelText contains "Video" then
        if enabled of b then
         click b
         return "OK"
        end if
       end if
      end repeat
     end repeat
    end tell
   end tell
  end timeout
 on error
  return "NONE"
 end try
 return "NONE"
end run
