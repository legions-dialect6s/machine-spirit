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
-- Minimized windows are restored before focusing/cycling — macOS's ⌘`
-- ignores them by design, which used to strand a minimized window forever
-- (the old browser-window-cycle bug). ⌘`/⌘N ride System Events, so the
-- whole ladder is browser-agnostic (Chromium ignores AppleScript window
-- reordering; the OS shortcut doesn't).
--
-- try-wrapped so any hiccup fails silently instead of throwing a
-- focus-stealing dialog at Leader Key; also invoked via run-quiet.sh.
on run argv
	try
		set browserName to item 1 of argv
		tell application "System Events"
			if not (exists application process browserName) then
				-- not running: launching it opens its own first window
				tell application browserName to activate
				return
			end if
			-- restore anything minimized so no window is stranded
			repeat with w in windows of application process browserName
				try
					if value of attribute "AXMinimized" of w is true then
						set value of attribute "AXMinimized" of w to false
					end if
				end try
			end repeat
			set frontApp to name of first application process whose frontmost is true
			if frontApp is not browserName then
				tell application browserName to activate
				if (count of (windows of application process browserName)) is 0 then
					keystroke "n" using command down
				end if
				return
			end if
			-- already frontmost: cycle in order, wrapping (⌘` = OS-native)
			set winCount to count of (windows of application process browserName)
			if winCount is 0 then
				keystroke "n" using command down
			else if winCount > 1 then
				keystroke "`" using command down
			end if
		end tell
	on error
		-- swallow: never block Leader Key with a dialog
	end try
end run
