#!/bin/bash
# SendSpin Post-Stop Hook
# Runs after SendSpin daemon stops via systemd ExecStopPost
# Handles cleanup and restoration

set -e

logger -t sendspin-spspost "Post-stop hook executed"

# The moOde worker handles MPD resume via stopSendspin() in renderer.php
# This hook can do additional cleanup if needed

# Clear metadata file (belt and suspenders)
rm -f /var/local/www/sendspinmeta.txt

# Log audio device status
if command -v fuser >/dev/null 2>&1; then
    fuser /dev/snd/pcmC0D0p 2>/dev/null && logger -t sendspin-spspost "Audio device still in use after stop" || logger -t sendspin-spspost "Audio device released"
fi

exit 0