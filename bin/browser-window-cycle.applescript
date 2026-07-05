-- browser-window-cycle.applescript
--
-- One button (bound to Leader Key s→a) that cycles the windows of whatever
-- browser is CURRENTLY frontmost — Safari, Chrome, Arc, Brave, Firefox:
--   * frontmost app isn't a known browser -> do nothing (silent)
--   * browser frontmost, 0 windows open    -> open a new window (⌘N)
--   * browser frontmost, 1 window          -> no-op (it's already focused)
--   * browser frontmost, N windows         -> advance to the next window,
--                                             wrapping around (⌘`)
--
-- Why System Events + ⌘` instead of each browser's own AppleScript: the native
-- `set index of window 1` reorder only actually cycles in Safari — in Chromium
-- browsers (Chrome/Brave/Arc) it's a no-op. macOS's own "Move focus to next
-- window" (⌘`) cycles + wraps identically in every Cocoa app, and ⌘N opens a
-- fresh window everywhere, so the whole thing is genuinely browser-agnostic and
-- touches no per-browser scripting dictionary.
--
-- The body is wrapped in try…on error…end try so any hiccup fails silently
-- instead of throwing a focus-stealing dialog at Leader Key (the crash-fix
-- convention); it is ALSO invoked through run-quiet.sh for belt-and-suspenders.
try
	set knownBrowsers to {"Safari", "Google Chrome", "Brave Browser", "Arc", "Firefox"}
	tell application "System Events"
		set frontApp to name of first application process whose frontmost is true
		if knownBrowsers does not contain frontApp then return
		set winCount to count of (windows of process frontApp)
		if winCount is 0 then
			-- browser frontmost but no windows: open a fresh one
			keystroke "n" using command down
		else if winCount > 1 then
			-- multiple windows: rotate to the next one (wraps around)
			keystroke "`" using command down
		end if
		-- winCount = 1: already the focused window, nothing to do
	end tell
on error
	-- swallow: never block Leader Key with a dialog
end try
