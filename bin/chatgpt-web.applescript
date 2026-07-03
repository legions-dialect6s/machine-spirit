tell application "Safari"
    activate
    set targetTab to missing value
    set targetWindow to missing value
    repeat with w in windows
        repeat with t in tabs of w
            set u to (URL of t)
            if u is not missing value then
                if u contains "chatgpt.com" or u contains "chat.openai.com" then
                    set targetTab to t
                    set targetWindow to w
                    exit repeat
                end if
            end if
        end repeat
        if targetTab is not missing value then exit repeat
    end repeat
    if targetTab is not missing value then
        set current tab of targetWindow to targetTab
        set index of targetWindow to 1
    else
        tell window 1 to set current tab to (make new tab with properties {URL:"https://chatgpt.com"})
    end if
end tell
