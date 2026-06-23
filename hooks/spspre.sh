#!/bin/bash
# =============================================================================
# SendSpin Pre-Play Hook (spspre.sh)
# =============================================================================
# Called before SendSpin starts audio playback.
# Detects whether CamillaDSP is enabled and routes audio accordingly.
#
# If CamillaDSP is enabled:
#   - Route SendSpin to hw:Loopback,0,0 (CamillaDSP input)
#   - This preserves room correction and parametric EQ
#
# If CamillaDSP is disabled:
#   - Use direct hardware (current Release 1 behaviour)
#   - No change needed, sendspin.conf already configured for hw:0,0
# =============================================================================

set -euo pipefail

DB_FILE="/var/local/www/db/moode-sqlite3.db"
ALSA_SENDSPIN_CONF="/etc/alsa/conf.d/sendspin.conf"
STATE_FILE="/var/local/www/sendspin_dsp_state.txt"

log() {
    logger -t sendspin-spspre "$1" 2>/dev/null || true
}

# Check if CamillaDSP is enabled in moOde
check_camilladsp() {
    if [ ! -f "$DB_FILE" ]; then
        echo "disabled"
        return
    fi

    # Query moOde database for CamillaDSP state
    DSP_STATE=$(sqlite3 "$DB_FILE" \
        "SELECT value FROM cfg_system WHERE param='camilladsp' LIMIT 1;" 2>/dev/null || echo "")

    if [ "$DSP_STATE" = "1" ] || [ "$DSP_STATE" = "on" ]; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Check if Loopback device exists
check_loopback() {
    if aplay -l 2>/dev/null | grep -q "Loopback"; then
        echo "available"
    else
        echo "unavailable"
    fi
}

DSP_STATE=$(check_camilladsp)
LOOPBACK=$(check_loopback)

log "CamillaDSP: $DSP_STATE, Loopback: $LOOPBACK"

if [ "$DSP_STATE" = "enabled" ] && [ "$LOOPBACK" = "available" ]; then
    # --- Route through CamillaDSP via Loopback ---

    cat > "$ALSA_SENDSPIN_CONF" << 'DSP_CONF'
# SendSpin ALSA config - CamillaDSP loopback mode
# Routes audio through CamillaDSP for room correction/EQ
pcm.sendspin {
    type plug
    slave {
        pcm {
            type hw
            card Loopback
            device 0
            subdevice 0
        }
        period_time 1160
        buffer_time 4640
    }
}
DSP_CONF

    echo "camilladsp" > "$STATE_FILE"
    log "Audio routed through CamillaDSP loopback"

else
    # --- Direct hardware mode (Release 1 default) ---
    # Detect audio card dynamically

    CARD_NUM=$(aplay -l 2>/dev/null | grep "^card" | head -1 | sed 's/card \([0-9]*\).*/\1/')
    CARD_NUM="${CARD_NUM:-0}"

    cat > "$ALSA_SENDSPIN_CONF" << DIRECT_CONF
# SendSpin ALSA config - Direct hardware mode
pcm.sendspin {
    type plug
    slave {
        pcm {
            type hw
            card ${CARD_NUM}
            device 0
        }
        period_time 1160
        buffer_time 4640
    }
}
DIRECT_CONF

    echo "direct" > "$STATE_FILE"
    log "Audio routed direct to hw:${CARD_NUM},0 (no DSP)"
fi

chmod 644 "$ALSA_SENDSPIN_CONF" 2>/dev/null || true
chmod 644 "$STATE_FILE" 2>/dev/null || true

# Stop MPD to release audio device (if not already stopped)
MPC_STATUS=$(mpc status 2>/dev/null | head -1 || echo "")
if echo "$MPC_STATUS" | grep -q "playing"; then
    mpc stop 2>/dev/null || true
    log "MPD stopped (was playing) - state saved by worker.php"
fi

exit 0
