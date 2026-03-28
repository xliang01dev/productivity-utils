# iPad Sidecar Toggle

A macOS shell script to connect or disconnect an iPad as a Sidecar display from the command line.

## Requirements

- macOS Tahoe
- iPad connected via Bluetooth (the script auto-detects the iPad name)
- Accessibility permissions granted to Terminal (or whichever app runs the script) under **System Settings → Privacy & Security → Accessibility**
- The **Screen Mirroring** icon must be set to **Always Show** in the menu bar: **System Settings → Menu Bar → Screen Mirroring → Always Show in Menu Bar**

## Files

- `toggle_ipad_sidecar.sh` — Main script; detects the iPad via Bluetooth and invokes the appropriate AppleScript.
- `enable_ipad_sidecar.scpt` — AppleScript that clicks through Control Center to enable Sidecar to the iPad.
- `disable_ipad_sidecar.scpt` — AppleScript that clicks through Control Center to disconnect the Sidecar display.

## Usage

1. Clone repo with shell script and AppleScript files.

2. Grant script permissions:
```bash
chmod 755 toggle_ipad_sidecar.sh
```

3. Run it:
```bash
./toggle_ipad_sidecar.sh -c   # Connect iPad as Sidecar display
./toggle_ipad_sidecar.sh -d   # Disconnect iPad Sidecar display
```

4. Alias it:
```bash
alias sideon="./path_to_script/toggle_ipad_sidecar.sh -c"
alias sideoff="./path_to_script/toggle_ipad_sidecar.sh -d"
```

## Notes

The AppleScripts automate Control Center UI interactions, so they depend on the menu bar item order staying consistent. If the script stops working after a macOS update, the menu bar item index or UI element paths in the `.scpt` files may need adjustment.
