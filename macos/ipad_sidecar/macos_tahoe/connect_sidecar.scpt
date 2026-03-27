tell application "System Events"
    tell process "ControlCenter"
        click menu bar item 10 of menu bar 1
        delay 1
        click checkbox 1 of group 1 of scroll area 1 of group 1 of window 1 -- First element is ipad screen mirroring
        delay 0.5
        key code 53 -- Escape key to dismiss the menu
    end tell
end tell