# SendSpin Release 2: Advanced Features Roadmap

**Branch:** `sendspin-advanced`
**Base:** `sendspin-integration` (Release 1)
**Target:** moOde 9.4.2+, SendSpin CLI 7.5.0+

---

## Overview

Release 2 builds on the core SendSpin integration (Release 1) with advanced
features for metadata display, volume synchronisation, CamillaDSP support,
and version management. These features were identified during the Release 1
code review as enhancements that require the core integration to be stable
first.

---

## Feature List

### 1. Now Playing Metadata Display (DONE - Implemented June 2026)

Display song title, artist, album, and cover art in moOde UI when streaming
from SendSpin via Music Assistant.

**Original Plan (hook-based):**
- SendSpin daemon `--hook-start` / `--hook-stop` scripts
- Metadata via `SENDSPIN_*` environment variables

**Actual Implementation (HA polling):**
- SendSpin hooks only pass connection info (server name, client ID) - NO track metadata
- Music Assistant advertises `metadata@v1` role but sends all-null fields (confirmed via raw WebSocket logging)
- MA sends only `server/hello`, `server/state` (null metadata), `group/update` (stopped), and `server/time` every 3s
- This is an MA-side bug; the SendSpin protocol itself fully supports metadata (ESPHome reference implementation proves this)

**Working Solution:**
- Standalone daemon (`sendspin-metadata-sink.py`) on port 8929
- Polls Home Assistant REST API every 3 seconds for `media_player.moode_sendspin` entity state
- Extracts title, artist, album, duration, and artwork URL from HA attributes
- Downloads cover art via HA proxy URL to `/var/local/www/imagesw/sendspin-covers/`
- Writes moOde metadata format to `/var/local/www/sendspinmeta.txt`: `Title~~~Artist~~~Album~~~Duration~~~CoverPath~~~Codec`
- Only rewrites file on track change (detected by title/artist comparison)
- Clears metadata when HA reports state other than playing/paused
- SendSpin WebSocket listener kept for connection monitoring only
- HA long-lived access token embedded in systemd service `Environment` directive

**Files:**
- `hooks/sendspin-metadata-sink.py` - Main daemon (HA polling + SendSpin listener)
- `/etc/systemd/system/sendspin-metadata-sink.service` - Service with HA_TOKEN env var
- `/var/local/www/sendspinmeta.txt` - Output metadata file (moOde ~~~ format)
- `/var/local/www/imagesw/sendspin-covers/` - Cached cover art directory

**Systemd Service:**
```ini
[Unit]
Description=SendSpin Metadata Sink for moOde (HA Polling)
After=network-online.target sendspin.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/root/.local/share/uv/tools/sendspin/bin/python /var/local/www/commandw/sendspin-metadata-sink.py
Restart=on-failure
RestartSec=10
Environment="HOME=/root"
Environment="HA_TOKEN=<long-lived-access-token>"
```

**Verified Working:**
- Track changes captured in real-time (< 3 second latency)
- Cover art downloads and caches correctly
- Metadata clears when playback stops
- Tested with multiple rapid track changes (Palehound, Big Thief, Japanese Breakfast, Angel Olsen, Waxahatchee)

---

### 2. Volume Synchronisation (Priority 2)

Two-way volume sync between Music Assistant and moOde.

**Approach:**
- SendSpin `--hook-set-volume` receives volume changes from controller
- Hook script writes volume to moOde's ALSA mixer via `amixer`
- moOde volume changes propagated back to SendSpin via CLI command

**Files:**
- `hooks/sendspin-volume-sync.sh` - Volume sync hook script
- `www/ren-config.php` - POST handler for sendspinvol
- `www/templates/ren-config.html` - Volume slider in SendSpin section

---

### 3. CamillaDSP Loopback Support (Priority 3)

Route SendSpin audio through moOde's CamillaDSP chain when DSP is enabled,
instead of direct hardware access. Preserves room correction and EQ.

**Approach:**
- Detect if CamillaDSP is enabled by checking `cfg_system` for `camilladsp`
- If enabled: route SendSpin to `hw:Loopback,0,0` (CamillaDSP input)
- If disabled: use direct hardware (current Release 1 behaviour)
- `spspre.sh` hook checks DSP state before playback starts

**Files:**
- `hooks/spspre.sh` - Pre-play hook for DSP detection
- `hooks/spspost.sh` - Post-play hook for state cleanup
- `etc/alsa/conf.d/sendspin.conf` - Updated with loopback option
- `www/inc/renderer.php` - `configureAlsaForSendspin()` updated

---

### 4. Buffer Tuning for Sync Precision (Priority 4)

Optimise ALSA buffer/period sizes for SendSpin's sub-millisecond sync.

**Approach:**
- Smaller period_time allows SendSpin's Kalman filter to adjust samples
  more precisely
- Add tunable parameters to sendspin.conf
- Test with various network conditions

**Configuration:**
```
pcm.sendspin {
    type plug
    slave {
        pcm {
            type hw
            card 0
            device 0
        }
        period_time 1160
        buffer_time 4640
    }
}
```

**Files:**
- `etc/alsa/conf.d/sendspin.conf` - Updated with buffer parameters
- `etc/alsa/conf.d/sendspin-hq.conf` - High-quality preset (optional)

---

### 5. Version Check and Update Button (Priority 5)

Show SendSpin CLI version in moOde UI with update notification.

**Approach:**
- PHP calls `sendspin --version` and `pip index versions sendspin`
- Display current version and "Update available" badge if newer exists
- One-click update via `uv tool upgrade sendspin`
- Restart service after update

**Files:**
- `www/inc/renderer.php` - `getSendspinVersion()` function
- `www/ren-config.php` - POST handler for sendspinupdate
- `www/templates/ren-config.html` - Version display + update button
- `www/daemon/worker.php` - Case handler for sendspinupdate

---

### 6. Systemd Service Hardening (Priority 6)

Run SendSpin as non-root user with proper audio group access.

**Approach:**
- Create `moodeaudio` user if not present (moOde standard user)
- Add `User=moodeaudio`, `SupplementaryGroups=audio,netdev` to service
- Add `LimitRTPRIO=99` and `LimitMEMLOCK=8388608` for real-time priority
- Ensure uv tool accessible to moodeaudio user

**Files:**
- `etc/systemd/system/sendspin.service` - Hardened service definition
- `moode-sendspin-installer.sh` - User creation logic

---

## Implementation Order

1. Metadata display (highest user value - visible improvement)
2. Volume sync (improves usability)
3. CamillaDSP support (addresses reviewer feedback)
4. Buffer tuning (performance optimisation)
5. Version check/update (maintenance convenience)
6. Service hardening (security improvement)

---

## Dependencies

- Release 1 (`sendspin-integration`) must be deployed and working
- SendSpin CLI 7.5.0+ (hook support verified)
- Home Assistant accessible from Pi on local network (port 8123)
- HA long-lived access token with read access to `media_player.moode_sendspin`
- Music Assistant integrated with Home Assistant (provides media_player entity)
- NOTE: Music Assistant does NOT populate SendSpin metadata@v1 fields (bug confirmed June 2026).
  HA polling is the workaround until MA fixes their server-side metadata implementation.

---

## Testing Strategy

Each feature will be tested on the Pi (192.168.214.25) with:
1. PHP syntax verification (`php -l`) before deployment
2. Manual hook testing with simulated environment variables
3. Web UI verification after deployment
4. Music Assistant streaming test for end-to-end validation

---

*Created June 23, 2026 on sendspin-advanced branch*
