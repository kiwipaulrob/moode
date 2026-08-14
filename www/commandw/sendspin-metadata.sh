#!/bin/bash
# SendSpin Metadata Hook — lightweight stream state marker
# Called by SendSpin daemon via --hook-start / --hook-stop.
# Defers to metadata sink daemon if it''s running.

SENDSPINMETA_FILE="/var/local/www/sendspinmeta.txt"

# If sink daemon is active, let it handle metadata — skip writing
if systemctl -q is-active sendspin-metadata-sink 2>/dev/null; then
    logger -t sendspin-metadata "Metadata sink daemon active — skipping hook write"
    exit 0
fi

# Fallback: write basic streaming status (JSON format, light footprint)
echo '{"status":"streaming"}' > "$SENDSPINMETA_FILE"
logger -t sendspin-metadata "Hook: streaming status written (no daemon)"
exit 0