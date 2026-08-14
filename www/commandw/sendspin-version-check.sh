#!/bin/bash
# SendSpin Version Check Script
# Checks PyPI for latest sendspin version
# Outputs JSON: {"installed": "x.y.z", "latest": "a.b.c", "update_available": true/false}

set -e

# Get installed version
INSTALLED_VERSION="unknown"
if command -v sendspin >/dev/null 2>&1; then
    INSTALLED_VERSION=$(sendspin --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
fi

# Get latest version from PyPI
LATEST_VERSION="unknown"
UPDATE_AVAILABLE=false

PYPI_JSON=$(curl -fsSL --max-time 5 "https://pypi.org/pypi/sendspin/json" 2>/dev/null || echo "{}")

if echo "$PYPI_JSON" | grep -q '"version"'; then
    LATEST_VERSION=$(echo "$PYPI_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('info', {}).get('version', 'unknown'))
" 2>/dev/null || echo "unknown")
    
    # Compare versions
    if [[ "$INSTALLED_VERSION" != "unknown" && "$LATEST_VERSION" != "unknown" ]]; then
        # Use Python for version comparison
        UPDATE_AVAILABLE=$(python3 -c "
import sys
from packaging import version
try:
    installed = version.parse('$INSTALLED_VERSION')
    latest = version.parse('$LATEST_VERSION')
    print('true' if latest > installed else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")
    fi
fi

# Output JSON
cat <<EOF
{
    "installed": "$INSTALLED_VERSION",
    "latest": "$LATEST_VERSION",
    "update_available": $UPDATE_AVAILABLE
}
EOF

exit 0