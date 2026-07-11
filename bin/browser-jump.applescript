-- browser-jump.applescript <Browser Name>
--
-- THE parameterized "open browser" action — one script, same ladder for
-- every browser, one Leader Key line per browser (web-jump's philosophy,
-- lifted to whole browsers). s→a runs it with "Safari", c→h→r with
-- "Google Chrome"; adding a browser is one config entry, no new script.
--
--   * browser not running            -> launch it (activate opens a window)
--   * running, other app frontmost   -> restore its minimized windows,
--                                       bring it forward (⌘N if none exist)
--   * already frontmost, 0 windows   -> open a fresh window (⌘N)
--   * already frontmost, N windows   -> advance to the next, wrapping (⌘`)
--
-- Structure matters: `activate` is done OUTSIDE the `tell "System Events"`
-- block. Nesting `tell application <browser> to activate` inside a System
-- Events tell silently fails (the whole point-of-failure of the first
-- cut) — so we gather state via System Events, end that tell, THEN drive
-- the app. Minimized windows are un-minimized first because macOS's ⌘`
-- skips them by design (the old stranded-window bug).
--
-- try-wrapped so any hiccup fails silently instead of throwing a
-- focus-stealing dialog at Leader Key; also invoked via run-quiet.sh.
on run argv
	try
		set browserName to item 1 of argv

		-- Not running: launch it and stop (its own first window opens).
		if not appRunning(browserName) then
			tell application browserName to activate
			return
		end if

		-- Gather state, and un-minimize, via System Events.
		set wasFrontmost to false
		set winCount to 0
		tell application "System Events"
			set wasFrontmost to (name of first application process whose frontmost is true) is browserName
			tell process browserName
				repeat with w in windows
					try
						if value of attribute "AXMinimized" of w is true then
							set value of attribute "AXMinimized" of w to false
						end if
					end try
				end repeat
				set winCount to count of windows
			end tell
		end tell

		if not wasFrontmost then
			-- Backgrounded: bring it forward (open one if it has none).
			tell application browserName to activate
			if winCount is 0 then keyCmd("n")
		else
			-- Already frontmost: cycle in order, wrapping (⌘` = OS-native).
			if winCount is 0 then
				keyCmd("n")
			else if winCount > 1 then
				keyCmd("`")
			end if
		end if
	on error
		-- swallow: never block Leader Key with a dialog
	end try
end run

on appRunning(appName)
	tell application "System Events" to return (exists application process appName)
end appRunning

on keyCmd(k)
	tell application "System Events" to keystroke k using command down
end keyCmd
