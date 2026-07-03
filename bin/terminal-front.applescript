-- Bring Terminal to the front, opening a fresh window if none exist
-- (plain app-launch won't spawn a window when Terminal is running but has none open).
tell application "Terminal" to reopen
tell application "Terminal" to activate
