-- center-window.applescript
-- Centers the frontmost window on whichever display it currently sits on,
-- without resizing it. Multi-monitor aware.
--
-- Wrapped in try…on error…end try so an app with no scriptable front window
-- (or one that refuses to be moved) fails silently — no focus-stealing dialog.
try
	tell application "System Events"
		set frontApp to first application process whose frontmost is true
		set win to front window of frontApp
		set {wx, wy} to position of win
		set {ww, wh} to size of win
	end tell

	set winCenterX to wx + (ww / 2)

	set frames to do shell script "
/usr/bin/osascript -l JavaScript -e '
ObjC.import(\"AppKit\");
var screens = $.NSScreen.screens;
var out = [];
for (var i = 0; i < screens.count; i++) {
  var f = screens.objectAtIndex(i).visibleFrame;
  out.push([f.origin.x, f.origin.y, f.size.width, f.size.height].join(\",\"));
}
out.join(\";\");
'
"

	set AppleScript's text item delimiters to ";"
	set screenFrames to text items of frames
	set AppleScript's text item delimiters to ","

	set targetFrame to item 1 of screenFrames
	repeat with fr in screenFrames
		set parts to text items of (fr as text)
		set ox to (item 1 of parts) as number
		set sw to (item 3 of parts) as number
		if winCenterX ≥ ox and winCenterX < (ox + sw) then
			set targetFrame to (fr as text)
			exit repeat
		end if
	end repeat

	set parts to text items of (targetFrame as text)
	set ox to (item 1 of parts) as number
	set oy to (item 2 of parts) as number
	set sw to (item 3 of parts) as number
	set sh to (item 4 of parts) as number

	set newX to ox + ((sw - ww) / 2)
	set newY to oy + ((sh - wh) / 2)

	set AppleScript's text item delimiters to ""
	tell application "System Events"
		set position of (front window of (first application process whose frontmost is true)) to {newX, newY}
	end tell
on error
	-- swallow: a failed centering must never block Leader Key with a dialog
end try
