tell application "System Events"
    tell process "ControlCenter"
        click menu bar item 10 of menu bar 1
        delay 1
        click UI element 2 of group 1 of scroll area 1 of group 1 of window 1 -- iPad element to click and disable is the first dropdown element
        delay 0.5
        key code 53 -- Escape key to dismiss the menu
    end tell
end tell