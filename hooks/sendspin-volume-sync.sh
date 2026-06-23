#!/bin/bash
# =============================================================================
# SendSpin Volume Synchronisation Hook
# =============================================================================
# Called by sendspin daemon via --hook-set-volume flag.
# Receives volume changes from Music Assistant and applies to moOde's
# ALSA mixer. Also supports reverse sync (moOde -> SendSpin) via CLI.
#
# Usage in sendspin.service:
#   --hook-set-volume /var/local/www/commandw/sendspin-volume-sync.sh
#
# Environment variables from SendSpin:
#   SENDSPIN_VOLUME   - Volume level 0-100
#   SENDSPIN_MUTED    - "1" if muted, "0" if not
# =============================================================================

set -euo pipefail

# Volume state file for cross-process communication
VOL_STATE_FILE="/var/local/www/sendspin_volume.txt"
MUTED_STATE_FILE="/var/local/www/sendspin_muted.txt"

log() {
    logger -t sendspin-volume "$1" 2>/dev/null || true
}

# Ensure state directory exists
mkdir -p "$(dirname "$VOL_STATE_FILE")"

# --- Incoming volume change from Music Assistant ---

if [ -n "${SENDSPIN_VOLUME:-}" ]; then
    VOLUME="${SENDSPIN_VOLUME}"

    # Validate range (0-100)
    if [ "$VOLUME" -lt 0 ] 2>/dev/null; then
        VOLUME=0
    elif [ "$VOLUME" -gt 100 ] 2>/dev/null; then
        VOLUME=100
    fi

    # Save state for moOde to read
    echo "$VOLUME" > "$VOL_STATE_FILE"
    chmod 644 "$VOL_STATE_FILE" 2>/dev/null || true

    # Apply to ALSA mixer
    # Try the sendspin softvol device first, fall back to hardware mixer
    if amixer -c 0 sset 'SendSpin' "${VOLUME}%" 2>/dev/null; then
        log "Volume set to ${VOLUME}% via SendSpin softvol"
    elif amixer -c 0 sset 'PCM' "${VOLUME}%" 2>/dev/null; then
        log "Volume set to ${VOLUME}% via PCM"
    elif amixer -c 0 sset 'Digital' "${VOLUME}%" 2>/dev/null; then
        log "Volume set to ${VOLUME}% via Digital"
    else
        log "Warning: Could not set ALSA volume to ${VOLUME}%"
    fi

    # Handle mute state
    if [ -n "${SENDSPIN_MUTED:-}" ]; then
        echo "${SENDSPIN_MUTED}" > "$MUTED_STATE_FILE"
        chmod 644 "$MUTED_STATE_FILE" 2>/dev/null || true

        if [ "${SENDSPIN_MUTED}" = "1" ]; then
            amixer -c 0 sset 'SendSpin' mute 2>/dev/null || \
            amixer -c 0 sset 'PCM' mute 2>/dev/null || true
            log "Muted"
        else
            amixer -c 0 sset 'SendSpin' unmute 2>/dev/null || \
            amixer -c 0 sset 'PCM' unmute 2>/dev/null || true
            log "Unmuted"
        fi
    fi

    log "Volume sync: ${VOLUME}% (muted: ${SENDSPIN_MUTED:-0})"
fi

# --- Reverse sync: moOde -> SendSpin ---
# Called by moOde when user changes volume in moOde UI
# Usage: sendspin-volume-sync.sh --set-volume 75
if [ "${1:-}" = "--set-volume" ] && [ -n "${2:-}" ]; then
    VOLUME="$2"
    sendspin set-volume "$VOLUME" 2>/dev/null && \
        log "Reverse sync: sent volume ${VOLUME}% to SendSpin" || \
        log "Reverse sync: failed to send volume to SendSpin"
    echo "$VOLUME" > "$VOL_STATE_FILE"
fi

# --- Get current volume (for moOde UI) ---
if [ "${1:-}" = "--get-volume" ]; then
    if [ -f "$VOL_STATE_FILE" ]; then
        cat "$VOL_STATE_FILE"
    else
        echo "50"
    fi
fi

exit 0
