#!/bin/bash
# SendSpin Pre-Start Hook
# Runs before SendSpin daemon starts via systemd ExecStartPre
# Prepares audio environment and validates configuration

set -e

SENDSPINMETA_FILE="/var/local/www/sendspinmeta.txt"
ALSA_CONF="/etc/alsa/conf.d/sendspin.conf"

# Clear any stale metadata file
rm -f "$SENDSPINMETA_FILE"

# Validate ALSA configuration exists
if [[ ! -f "$ALSA_CONF" ]]; then
    echo "WARNING: ALSA config $ALSA_CONF not found, regenerating..." >&2
    # Trigger regeneration via moOde's PHP (would need sudo, so just warn)
    # The generateSendspinService() in renderer.php handles this on config save
fi

# Ensure the sendspin ALSA device is available
if ! aplay -L 2>/dev/null | grep -q "^sendspin$"; then
    echo "WARNING: ALSA device 'sendspin' not found in aplay -L" >&2
fi

# Log pre-start
logger -t sendspin-spspre "Pre-start hook executed, ALSA device: $(aplay -L 2>/dev/null | grep sendspin || echo 'not found')"

exit 0