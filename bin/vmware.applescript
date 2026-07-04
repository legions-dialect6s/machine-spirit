-- vmware.applescript
-- Activate VMware Fusion if it's already running; launch it if it isn't.
--
-- Note: cycling between individual running-VM windows is not cleanly
-- scriptable — VMware Fusion doesn't expose its VM windows to AppleScript's
-- System Events window list in a stable, addressable way. So this just brings
-- the app forward (or starts it). Use macOS window-cycling (⌘`) once focused
-- to move between open VM windows.
set appName to "VMware Fusion"
if application appName is running then
	tell application appName to activate
else
	tell application appName to launch
	tell application appName to activate
end if
