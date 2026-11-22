#!/bin/zsh
# Safari decides which windows can merge, including its private/profile boundaries.
emulate -L zsh
[[ ${MS_HOLD_N:-1} == 1 ]] || exit 10
result=$(/usr/bin/osascript - "${1:-}" <<'AS'
on identified(itemsToCheck, expected)
 tell application "System Events"
  repeat with candidate in itemsToCheck
   try
    if value of attribute "AXIdentifier" of candidate is expected then return contents of candidate
   end try
  end repeat
 end tell
 return missing value
end identified

on run argv
 with timeout of 3 seconds
  tell application "System Events"
   set safari to first application process whose bundle identifier is "com.apple.Safari"
   -- A direct lookup avoids walking the menu tree on English systems.
   -- Confirm the stable identifier and fall back to it in other locales.
   set mergeItem to missing value
   try
    set candidate to menu item "Merge All Windows" of menu 1 of menu bar item "Window" of menu bar 1 of safari
    if value of attribute "AXIdentifier" of candidate is "MergeAllWindows" then set mergeItem to candidate
   end try
   if mergeItem is missing value then
    set windowMenu to my identified(menu bar items of menu bar 1 of safari, "SafariWindowMenu")
    if windowMenu is missing value then return "UNAVAILABLE"
    set mergeItem to my identified(menu items of menu 1 of windowMenu, "MergeAllWindows")
   end if
   if mergeItem is missing value then return "UNAVAILABLE"
   if not enabled of mergeItem then return "DONE"
   if item 1 of argv is not "--check" then click mergeItem
   return "READY"
  end tell
 end timeout
end run
AS
) || exit 11
case $result in
 READY|DONE) exit 10 ;;
 *) exit 11 ;;
esac
