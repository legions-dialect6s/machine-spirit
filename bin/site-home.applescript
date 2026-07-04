tell application "Safari"
    set u to URL of current tab of front window
    set AppleScript's text item delimiters to "/"
    set parts to text items of u
    set homeURL to (item 1 of parts) & "//" & (item 3 of parts) & "/"
    set URL of current tab of front window to homeURL
end tell
