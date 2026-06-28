#!/bin/bash
# =============================================================================
# SendSpin Metadata Capture Hook
# =============================================================================
# Called by sendspin daemon via --hook-start and --hook-stop flags.
# Receives metadata via SENDSPIN_* environment variables and writes to
# moOde's metadata file format (~~~ delimited).
#
# Usage in sendspin.service:
#   --hook-start /var/local/www/commandw/sendspin-metadata.sh
#   --hook-stop /var/local/www/commandw/sendspin-metadata.sh
#
# moOde metadata format: Title~~~Artist~~~Album~~~Duration~~~CoverPath~~~Codec
# =============================================================================

set -euo pipefail

META_FILE="/var/local/www/sendspinmeta.txt"
COVER_DIR="/var/local/www/imagesw/sendspin-covers"

# Ensure directories exist
mkdir -p "$COVER_DIR"
mkdir -p "$(dirname "$META_FILE")"

# Log function for debugging
log() {
    logger -t sendspin-metadata "$1" 2>/dev/null || true
}

# Sanitise field - remove ~~~ delimiters and control characters
sanitise() {
    echo -n "$1" | tr -d '\000-\010\013\014\016-\037' | sed 's/~~~/ /g'
}

# SendSpin passes SENDSPIN_EVENT (start/stop), not SENDSPIN_STATE
if [ "${SENDSPIN_EVENT:-}" = "start" ]; then
    # --- Stream started: capture metadata ---

    TITLE=$(sanitise "${SENDSPIN_TITLE:-Streaming}")
    ARTIST=$(sanitise "${SENDSPIN_ARTIST:-SendSpin}")
    ALBUM=$(sanitise "${SENDSPIN_ALBUM:-}")
    DURATION=$(sanitise "${SENDSPIN_DURATION:-0}")
    CODEC=$(sanitise "${SENDSPIN_CODEC:-SendSpin}")
    SERVER=$(sanitise "${SENDSPIN_SERVER_NAME:-}")

    # Use server name as artist if no metadata available
    # SendSpin 7.5.0 hooks only pass connection info, not track metadata
    if [ "$TITLE" = "Streaming" ] && [ -n "$SERVER" ]; then
        ARTIST="via $SERVER"
    fi

    # Download cover art if URL provided
    COVER_PATH=""
    if [ -n "${SENDSPIN_COVER_URL:-}" ]; then
        # Generate filename from URL hash to avoid re-downloading
        COVER_HASH=$(echo -n "${SENDSPIN_COVER_URL}" | md5sum | cut -d' ' -f1)
        COVER_FILE="${COVER_DIR}/cover-${COVER_HASH}.jpg"

        if [ ! -f "$COVER_FILE" ]; then
            # Download with 5-second timeout, max 2MB
            curl -sfL --max-time 5 --max-filesize 2097152 \
                -o "$COVER_FILE" "${SENDSPIN_COVER_URL}" 2>/dev/null || {
                log "Failed to download cover art from ${SENDSPIN_COVER_URL}"
                rm -f "$COVER_FILE"
            }
        fi

        if [ -f "$COVER_FILE" ]; then
            COVER_PATH="imagesw/sendspin-covers/$(basename "$COVER_FILE")"
        fi
    fi

    # Write metadata file (moOde ~~~ format)
    # Don't overwrite if the file already has valid track data from the HA sink.
    # SendSpin hooks only pass connection info, not real track metadata.
    if [ -f "$META_FILE" ]; then
        EXISTING_CONTENT=$(cat "$META_FILE" 2>/dev/null || echo "")
        if echo "$EXISTING_CONTENT" | grep -q "~~~SendSpin~~~Stopped~~~" || [ -z "$EXISTING_CONTENT" ]; then
            echo -e "${TITLE}~~~${ARTIST}~~~${ALBUM}~~~${DURATION}~~~${COVER_PATH}~~~${CODEC}" > "$META_FILE"
        else
            log "Skipping hook write - file has real metadata from HA sink"
        fi
    else
        echo -e "${TITLE}~~~${ARTIST}~~~${ALBUM}~~~${DURATION}~~~${COVER_PATH}~~~${CODEC}" > "$META_FILE"
    fi

    # Set permissions so web server can read
    chmod 644 "$META_FILE" 2>/dev/null || true
    chown www-data:www-data "$META_FILE" 2>/dev/null || true

    log "Stream started: ${TITLE} by ${ARTIST} (event=start)"

elif [ "${SENDSPIN_EVENT:-}" = "stop" ] || [ -z "${SENDSPIN_EVENT:-}" ]; then
    # --- Stream stopped: clear metadata ---

    echo -e "~~~SendSpin~~~Stopped~~~0~~~~~~" > "$META_FILE"
    chmod 644 "$META_FILE" 2>/dev/null || true
    chown www-data:www-data "$META_FILE" 2>/dev/null || true

    log "Stream stopped (event=stop)"

else
    log "Unknown SENDSPIN_EVENT: ${SENDSPIN_EVENT:-empty}"
fi

# Clean up old cover art (keep last 50 files)
find "$COVER_DIR" -name "cover-*.jpg" -type f -printf '%T@ %p\n' 2>/dev/null | \
    sort -rn | tail -n +51 | cut -d' ' -f2- | xargs rm -f 2>/dev/null || true

exit 0
