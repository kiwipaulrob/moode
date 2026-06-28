#!/bin/bash
# =============================================================================
# SendSpin Metadata Capture Hook (stub)
# =============================================================================
# Formerly wrote placeholder metadata via --hook-start/--hook-stop.
# The HA metadata-sink (sendspin-metadata-sink.py) handles all metadata
# via direct HA API polling -- it is more reliable and includes cover art.
# This stub remains installed for backward compatibility.
# =============================================================================
logger -t sendspin-metadata "Hook called (SENDSPIN_EVENT=${SENDSPIN_EVENT:-none}) - metadata handled by HA sink"
exit 0
