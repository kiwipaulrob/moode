#!/bin/bash
set -euo pipefail

DB_FILE="/var/local/www/db/moode-sqlite3.db"
STATE_FILE="/dev/shm/sendspin_state.json"

log() {
    logger -t sendspin-spspre "$1" 2>/dev/null || true
}

# Read card number from DB (supports any ALSA card)
CARD_NUM=$(sqlite3 "$DB_FILE" "SELECT value FROM cfg_system WHERE param='cardnum';" 2>/dev/null || echo "0")

# ALSA config with dynamic card number
cat > /etc/alsa/conf.d/sendspin.conf << EOF
pcm.sendspin {
type plug
slave {
pcm "plughw:${CARD_NUM},0"
}
}
EOF
chmod 644 /etc/alsa/conf.d/sendspin.conf 2>/dev/null || true
echo "direct" > /var/local/www/sendspin_dsp_state.txt
chmod 644 /var/local/www/sendspin_dsp_state.txt 2>/dev/null || true

# Set active state in shared memory
echo '{"active":1}' > "$STATE_FILE"
chmod 644 "$STATE_FILE" 2>/dev/null || true

# Update DB so worker.php chkSendspinActive() can detect it
sqlite3 "$DB_FILE" "UPDATE cfg_system SET value='1' WHERE param='sendspinactive';" 2>/dev/null || true
log "SendSpin active state set to 1 (shm + db)"

# Stop MPD if playing
MPC_STATUS=$(mpc status 2>/dev/null | head -1 || echo "")
if echo "$MPC_STATUS" | grep -q "playing"; then
    mpc stop 2>/dev/null || true
    log "MPD stopped (was playing)"
fi

exit 0
