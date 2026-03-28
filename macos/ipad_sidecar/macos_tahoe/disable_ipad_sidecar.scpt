-- Ensure ControlCenter is running
if not (application "ControlCenter" is running) then
    do shell script "open /System/Library/CoreServices/ControlCenter.app"
    delay 2
end if

tell application "System Events"
    tell process "ControlCenter"
        set frontmost to true
        delay 0.5

        -- Find Screen Mirroring by description instead of hardcoded index
        set targetItem to missing value
        set mbItems to every menu bar item of menu bar 1
        repeat with i from 1 to count of mbItems
            set itemDesc to description of item i of mbItems
            if itemDesc contains "Screen Mirroring" then
                set targetItem to item i of mbItems
                exit repeat
            end if
        end repeat

        if targetItem is missing value then
            return
        end if

        -- Open Screen Mirroring panel
        click targetItem
        delay 1

        -- Click the disclosure triangle to expand device options
        try
            set disclosureTriangle to UI element 2 of group 1 of scroll area 1 of group 1 of window 1
            click disclosureTriangle
        end try

        -- Dismiss the Control Center panel
        delay 1
        key code 53 -- Escape
    end tell
end tell