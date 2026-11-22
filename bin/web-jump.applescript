-- web-jump.applescript <domains> [fallback-url]
-- Focus or cycle matching tabs in the selected browser, or open the fallback URL.
-- Keep this entry point for existing Leader Key bindings.
on run argv
	try
		if (count of argv) < 1 or (count of argv) > 2 then return
		set scriptPath to POSIX path of (path to me)
		set helperPath to do shell script "/usr/bin/dirname " & quoted form of scriptPath
		set commandText to "/usr/bin/osascript -l JavaScript " & quoted form of (helperPath & "/web-browser.js") & " jump"
		repeat with arg in argv
			set commandText to commandText & " " & quoted form of (contents of arg)
		end repeat
		if (count of argv) is 1 then set commandText to commandText & " ''"
		if (do shell script commandText) is "SAFARI" then my safariJump(argv, commandText)
	on error
		-- Keep focus-stealing script errors out of Leader Key.
	end try
end run

on safariJump(argv, commandText)
	try
		set domainArg to item 1 of argv
		set AppleScript's text item delimiters to ","
		set domainList to text items of domainArg
		set AppleScript's text item delimiters to ""
		set fallbackURL to "https://" & (item 1 of domainList)
		if (count of argv) > 1 then
			if item 2 of argv is not "" then set fallbackURL to item 2 of argv
		end if

		with timeout of 2 seconds
			tell application id "com.apple.Safari"
				activate
				if (count of windows) = 0 then
					make new document with properties {URL:fallbackURL}
					return
				end if
				set frontID to id of front window
				set curIdx to index of current tab of front window

				-- collect every matching tab as {window id, tab index}, noting where
				-- the current tab sits in that list (0 = current tab doesn't match)
				set matchList to {}
				set curPos to 0
				repeat with w in windows
					set wid to id of w
					set tcount to count of tabs of w
					repeat with ti from 1 to tcount
						set u to URL of tab ti of w
						if u is not missing value and my matchesAny(u, domainList) then
							set end of matchList to {wid, ti}
							if wid = frontID and ti = curIdx then set curPos to (count of matchList)
						end if
					end repeat
				end repeat

				if (count of matchList) = 0 then
					tell front window to set current tab to (make new tab with properties {URL:fallbackURL})
					return
				end if

				if curPos = 0 then
					set target to item 1 of matchList
				else
					set target to item ((curPos mod (count of matchList)) + 1) of matchList
				end if
				set {wid, ti} to target
				repeat with w in windows
					if id of w = wid then
						set current tab of w to tab ti of w
						set index of w to 1
						exit repeat
					end if
				end repeat
			end tell
		end timeout
	on error
		do shell script commandText & " open"
	end try
end safariJump

on matchesAny(u, domainList)
	repeat with d in domainList
		if (contents of d) is not "" and u contains (contents of d) then return true
	end repeat
	return false
end matchesAny
