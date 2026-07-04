-- terminal-front.applescript
-- Bring Terminal to the front, opening a fresh window if none exist
-- (plain app-launch won't spawn a window when Terminal is running but has none open).
--
-- Wrapped in try…on error…end try so a Terminal scripting hiccup fails silently
-- instead of throwing a focus-stealing dialog that blocks Leader Key.
try
	tell application "Terminal" to reopen
	tell application "Terminal" to activate
on error
	-- swallow: never block Leader Key with a dialog
end try
