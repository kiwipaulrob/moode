#!/bin/bash
# SendSpin Metadata Hook
# Called by SendSpin daemon via --hook-start and --hook-stop
# Arguments: $1 = event (start|stop), $2 = JSON metadata (on start)

set -e

SENDSPINMETA_FILE="/var/local/www/sendspinmeta.txt"
EVENT="${1:-}"
METADATA_JSON="${2:-}"

case "$EVENT" in
    start)
        # Write metadata to file for moOde to read
        # METADATA_JSON contains: title, artist, album, artwork_url, etc.
        echo "$METADATA_JSON" > "$SENDSPINMETA_FILE"
        logger -t sendspin-metadata "Stream started, metadata written"
        ;;
    stop)
        # Clear metadata file
        rm -f "$SENDSPINMETA_FILE"
        logger -t sendspin-metadata "Stream stopped, metadata cleared"
        ;;
    *)
        logger -t sendspin-metadata "Unknown event: $EVENT"
        exit 1
        ;;
esac

exit 0