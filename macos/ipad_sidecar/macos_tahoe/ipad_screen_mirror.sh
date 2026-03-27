#!/bin/bash

IPAD_NAME=$(system_profiler SPBluetoothDataType 2>/dev/null | grep -i "ipad" | sed 's/^[[:space:]]*//;s/:[[:space:]]*$//' | head -1)

usage() {
    echo "Usage: $0 -c | -d"
    echo "  -c  Connect iPad as Sidecar display"
    echo "  -d  Disconnect iPad Sidecar display"
    exit 1
}

while getopts "cd" opt; do
    case $opt in
        c)
            echo "Connecting iPad \"$IPAD_NAME\" as Sidecar display"
            osascript "$(dirname "$0")/connect_sidecar.scpt"
            ;;
        d)
            echo "Disconnecting iPad \"$IPAD_NAME\" Sidecar display"
            osascript "$(dirname "$0")/disconnect_sidecar.scpt"
            ;;
        *)
            usage
            ;;
    esac
done

[[ $OPTIND -eq 1 ]] && usage
