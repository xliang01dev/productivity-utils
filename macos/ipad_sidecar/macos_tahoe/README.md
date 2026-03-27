# iPad Sidecar Toggle

A macOS shell script to connect or disconnect an iPad as a Sidecar display from the command line.


## Requirements

- macOS Tahoe
- iPad connected via Bluetooth (the script auto-detects the iPad name)
- Accessibility permissions granted to Terminal (or whichever app runs the script) under **System Settings → Privacy & Security → Accessibility**
- The **Screen Mirroring** icon must be set to **Always Show** in the menu bar: **System Settings → Menu Bar → Screen Mirroring → Always Show in Menu Bar**

## Files

- `ipad_screen_mirror.sh` — Main script; detects the iPad via Bluetooth and invokes the appropriate AppleScript.
- `connect_sidecar.scpt` — AppleScript that clicks through Control Center to enable screen mirroring to the iPad.
- `disconnect_sidecar.scpt` — AppleScript that clicks through Control Center to disconnect the Sidecar display.

## Usage

```bash
./ipad_screen_mirror.sh -c   # Connect iPad as Sidecar display
./ipad_screen_mirror.sh -d   # Disconnect iPad Sidecar display
```

Alias it:
```bash
alias mirror = "./ipad_screen_mirror.sh -c"
alias disconnect = "./ipad_screen_mirror.sh -d"
```

## Notes

The AppleScripts automate Control Center UI interactions, so they depend on the menu bar item order staying consistent. If the script stops working after a macOS update, the menu bar item index or UI element paths in the `.scpt` files may need adjustment.
