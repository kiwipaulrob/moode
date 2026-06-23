#!/bin/bash
# =============================================================================
# SendSpin Post-Play Hook (spspost.sh)
# =============================================================================
# Called when SendSpin stops audio playback.
# Cleans up state and optionally returns ALSA device to MPD.
# =============================================================================

set -euo pipefail

STATE_FILE="/var/local/www/sendspin_dsp_state.txt"
META_FILE="/var/local/www/sendspinmeta.txt"

log() {
    logger -t sendspin-spspost "$1" 2>/dev/null || true
}

# Clear metadata
if [ -f "$META_FILE" ]; then
    echo -e "~~~SendSpin~~~Stopped~~~0~~~~~~" > "$META_FILE"
    chmod 644 "$META_FILE" 2>/dev/null || true
fi

# Log previous DSP state for debugging
if [ -f "$STATE_FILE" ]; then
    PREV_STATE=$(cat "$STATE_FILE")
    log "Post-play cleanup (was using: $PREV_STATE)"
else
    log "Post-play cleanup (no previous state found)"
fi

# Note: MPD resume is handled by worker.php stopSendspin() function
# which checks $_SESSION['mpd_was_playing'] before resuming.
# This hook only handles ALSA-level cleanup.

exit 0
