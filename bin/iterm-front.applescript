-- iterm-front.applescript — bring iTerm2 and ALL its windows to the front.
-- Bound to Leader Key  i t. Plain app-launch only foregrounds the app; this
-- activates it AND raises every window (and opens one if none exist).
--
-- Note (macOS limit): `activate` raises all of iTerm's windows on the CURRENT
-- Space. Windows parked on OTHER Spaces aren't pulled forward — macOS/Mission
-- Control doesn't allow yanking windows across Spaces programmatically.
try
	tell application "iTerm2" to activate
	tell application "System Events"
		tell application process "iTerm2"
			if (count of windows) = 0 then
				keystroke "n" using command down
			end if
		end tell
	end tell
on error
	-- swallow: never block Leader Key with a dialog
end try
