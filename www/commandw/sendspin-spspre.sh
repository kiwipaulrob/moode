#!/bin/bash
# SendSpin Pre-Start Hook
# Runs before SendSpin daemon starts via systemd ExecStartPre
# Validates audio environment -- uses moOde's standard _audioout device

SENDSPINMETA_FILE="/var/local/www/sendspinmeta.txt"

# Clear any stale metadata file
rm -f "$SENDSPINMETA_FILE"

# Validate the _audioout ALSA device is available
if ! aplay -L 2>/dev/null | grep -q "^_audioout$"; then
    echo "WARNING: ALSA device '_audioout' not found in aplay -L" >&2
fi

# Log pre-start
logger -t sendspin-spspre "Pre-start hook executed, using moOde _audioout device"
exit 0