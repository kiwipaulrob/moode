#!/bin/bash
# =============================================================================
# SendSpin Post-Stop Hook (spspost.sh)
# =============================================================================
# Called after sendspin.service stops.
# Metadata cleanup is handled by the HA metadata-sink daemon
# (sendspin-metadata-sink.py) which detects stream state independently.
# MPD resume is handled by inc/renderer.php stopSendspin().
# =============================================================================
logger -t sendspin-spspost "SendSpin stopped (cleanup handled by HA sink)"
exit 0
