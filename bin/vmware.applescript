-- vmware.applescript
-- Activate VMware Fusion if it's already running; launch it if it isn't.
--
-- Note: cycling between individual running-VM windows is not cleanly
-- scriptable — VMware Fusion doesn't expose its VM windows to AppleScript's
-- System Events window list in a stable, addressable way. So this just brings
-- the app forward (or starts it). Use macOS window-cycling (⌘`) once focused
-- to move between open VM windows.
--
-- Wrapped in try…on error…end try so a launch/activate failure fails silently
-- rather than throwing a focus-stealing dialog that blocks Leader Key.
try
	set appName to "VMware Fusion"
	if application appName is running then
		tell application appName to activate
	else
		tell application appName to launch
		tell application appName to activate
	end if
on error
	-- swallow: never block Leader Key with a dialog
end try
