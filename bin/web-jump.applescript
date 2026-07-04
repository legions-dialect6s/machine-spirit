-- web-jump.applescript <domains> [fallback-url]
--
-- Universal focus-or-cycle-or-open for websites in Safari:
--   * no matching tab anywhere      -> open fallback (default https://<first domain>)
--   * matching tabs exist, current tab isn't one -> focus the first match
--   * current tab already matches   -> jump to the NEXT matching tab (wraps, across windows)
--
-- domains is a comma-separated list matched as substrings of tab URLs:
--   osascript web-jump.applescript youtube.com
--   osascript web-jump.applescript x.com,twitter.com
--   osascript web-jump.applescript chatgpt.com,chat.openai.com
--   osascript web-jump.applescript github.com https://github.com/notifications
on run argv
	set domainArg to item 1 of argv
	set AppleScript's text item delimiters to ","
	set domainList to text items of domainArg
	set AppleScript's text item delimiters to ""
	if (count of argv) > 1 then
		set fallbackURL to item 2 of argv
	else
		set fallbackURL to "https://" & (item 1 of domainList)
	end if

	tell application "Safari"
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
end run

on matchesAny(u, domainList)
	repeat with d in domainList
		if u contains (contents of d) then return true
	end repeat
	return false
end matchesAny
