#!/bin/bash
# =============================================================================
# SendSpin Version Check Script
# =============================================================================
# Checks installed SendSpin CLI version against latest available on PyPI.
# Returns JSON for moOde PHP to consume.
#
# Usage: sendspin-version-check.sh
# Output: {"installed":"7.5.0","latest":"7.6.0","update_available":true}
# =============================================================================

set -euo pipefail

# Get installed version
INSTALLED=$(sendspin --version 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "unknown")

# Get latest version from PyPI
LATEST=$(pip index versions sendspin 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "")

if [ -z "$LATEST" ]; then
    # Fallback: check via uv
    LATEST=$(uv tool list 2>/dev/null | grep sendspin | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "")
fi

# Compare versions
UPDATE_AVAILABLE="false"
if [ "$INSTALLED" != "unknown" ] && [ -n "$LATEST" ] && [ "$INSTALLED" != "$LATEST" ]; then
    UPDATE_AVAILABLE="true"
fi

# Output JSON
echo "{\"installed\":\"${INSTALLED}\",\"latest\":\"${LATEST:-unknown}\",\"update_available\":${UPDATE_AVAILABLE}}"

exit 0
