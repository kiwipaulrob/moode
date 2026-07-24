#!/bin/bash
# SendSpin Metadata Hook — lightweight stream state marker
# Called by SendSpin daemon via --hook-start / --hook-stop
# Does NOT overwrite rich metadata written by the metadata sink daemon.

SENDSPINMETA_FILE="/var/local/www/sendspinmeta.txt"

# If sink daemon already wrote rich metadata (~~~ format), don't touch it
if [ -f "$SENDSPINMETA_FILE" ] && grep -q "~~~" "$SENDSPINMETA_FILE" 2>/dev/null; then
    logger -t sendspin-metadata "Rich metadata present — skipping hook write"
    exit 0
fi

# Write basic streaming status
echo "{\"status\":\"streaming\"}" > "$SENDSPINMETA_FILE"
logger -t sendspin-metadata "Hook: streaming status written"
exit 0