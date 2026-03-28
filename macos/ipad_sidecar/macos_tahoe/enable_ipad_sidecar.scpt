on run argv
    set iPadName to item 1 of argv
    
    do shell script "open 'x-apple.systempreferences:com.apple.Displays-Settings.extension'"
    delay 0.5
    
    tell application "System Events"
        tell process "System Settings"
            click menu button 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1
            delay 1
            click menu item iPadName of menu 1 of menu button 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1
            delay 0.5
            key code 53 -- Escape key to dismiss the menu
        end tell
    end tell
    
    tell application "System Settings" to quit
end run
