-- web-collect.sh <domains> [fallback-url]: gather one Safari tab per hold press.
-- Internal argv: domains, fallback (reserved; a miss never opens a tab), state, N.
-- Darwin 25 Safari supports native tab move; only -1708 falls back to URL-copy
-- then close (which cannot preserve navigation history/form state). Other errors
-- leave the source alone. Scan URLs once per invocation, in window/tab order.
-- New windows appear asynchronously: identify our unique blank starter before
-- using its ID, rather than trusting the temporarily stale front-window value.
-- No timers run when idle; all errors return NONE without showing a dialog.
on run argv
	try
		if (count of argv) < 4 then return "NONE"
		set AppleScript's text item delimiters to ","
		set domainList to text items of item 1 of argv
		set AppleScript's text item delimiters to ""
		set statePath to item 3 of argv
		set collectorID to 0
		if item 4 of argv is not "1" then
			try
				set collectorID to (read POSIX file statePath) as integer
			end try
		end if
		if not application "Safari" is running then return "NONE"
		with timeout of 2 seconds
			tell application "Safari"
				set windowIDs to id of every window
				set allURLs to URL of every tab of every window
			end tell
			if windowIDs does not contain collectorID then set collectorID to 0
			set matches to {}
			set outside to {}
			repeat with wi from 1 to count of windowIDs
				set wid to item wi of windowIDs
				set tabURLs to item wi of allURLs
				repeat with ti from 1 to count of tabURLs
					set u to item ti of tabURLs
					if u is not missing value and my matchesAny(u, domainList) then
						set hit to {wid, ti, u}
						set end of matches to hit
						if wid is not collectorID then set end of outside to hit
					end if
				end repeat
			end repeat
			if matches is {} then return "NONE"
			if collectorID = 0 then
				set firstID to item 1 of item 1 of matches
				set onlyOneWindow to true
				repeat with hit in matches
					if item 1 of hit is not firstID then set onlyOneWindow to false
				end repeat
				set firstCount to 0
				repeat with wi from 1 to count of windowIDs
					if item wi of windowIDs = firstID then set firstCount to count of item wi of allURLs
				end repeat
				if onlyOneWindow and firstCount = (count of matches) then
					set collectorID to firstID
					my saveID(statePath, collectorID)
					return my cycleCollector(collectorID)
				end if
				set collectorID to my newCollector(windowIDs)
				if collectorID = 0 then return "NONE"
				try
					my moveMatch(item 1 of matches, collectorID)
				on error
					-- Only discard the starter if it is still our sole blank tab.
					tell application "Safari"
						if (count of tabs of window id collectorID) = 1 then close window id collectorID
					end tell
					return "NONE"
				end try
				tell application "Safari" to close tab 1 of window id collectorID
				my saveID(statePath, collectorID)
				my focusCollector(collectorID)
				try
					do shell script "\"$HOME/bin/ms\" win place smart >/dev/null 2>&1 || true"
				end try
				return "OK"
			end if
			if outside is {} then return my cycleCollector(collectorID)
			my moveMatch(item 1 of outside, collectorID)
			my focusCollector(collectorID)
			if (count of outside) = 1 then return "DONE"
			return "OK"
		end timeout
	on error
		return "NONE"
	end try
end run

on matchesAny(u, domainList)
	repeat with d in domainList
		if (contents of d) is not "" and u contains (contents of d) then return true
	end repeat
	return false
end matchesAny

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

on newCollector(beforeIDs)
	set marker to "about:blank#ms-collect-" & (random number from 100000000 to 999999999)
	tell application "Safari" to make new document with properties {URL:marker}
	repeat 10 times
		tell application "Safari" to set currentIDs to id of every window
		repeat with wid in currentIDs
			if beforeIDs does not contain (contents of wid) then
				tell application "Safari"
					try
						if URL of tab 1 of window id (contents of wid) is marker then return contents of wid
					end try
				end tell
			end if
		end repeat
		delay 0.02
	end repeat
	return 0
end newCollector

on moveMatch(hit, collectorID)
	set {sourceID, ti, expectedURL} to hit
	tell application "Safari"
		-- Revalidate before a destructive operation if Safari changed during scan.
		if URL of tab ti of window id sourceID is not expectedURL then error "Tab changed"
		try
			move tab ti of window id sourceID to end of tabs of window id collectorID
		on error errText number errNum
			if errNum is not -1708 then error errText number errNum
			make new tab at end of tabs of window id collectorID with properties {URL:expectedURL}
			if URL of tab ti of window id sourceID is expectedURL then close tab ti of window id sourceID
		end try
		set current tab of window id collectorID to last tab of window id collectorID
	end tell
end moveMatch

on focusCollector(wid)
	tell application "Safari"
		set index of window id wid to 1
		activate
	end tell
end focusCollector

on cycleCollector(wid)
	tell application "Safari"
		set n to count of tabs of window id wid
		if n = 0 then return "NONE"
		set i to index of current tab of window id wid
		set current tab of window id wid to tab ((i mod n) + 1) of window id wid
	end tell
	my focusCollector(wid)
	return "OK"
end cycleCollector
