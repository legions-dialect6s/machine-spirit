-- site-home.applescript
-- Strips the current Safari tab's URL back to the site's home page (scheme +
-- host + "/"). Wrapped in try…on error…end try so a missing window / odd URL
-- fails silently instead of throwing a focus-stealing dialog at Leader Key.
try
	tell application "Safari"
		set u to URL of current tab of front window
		set AppleScript's text item delimiters to "/"
		set parts to text items of u
		set homeURL to (item 1 of parts) & "//" & (item 3 of parts) & "/"
		set URL of current tab of front window to homeURL
	end tell
on error
	-- swallow: never block Leader Key with a dialog
end try
