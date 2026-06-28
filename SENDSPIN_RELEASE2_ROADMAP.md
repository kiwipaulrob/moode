# SendSpin for moOde — Feature Status

**Branch:** `sendspin-advanced`
**Updated:** 2026-06-28

## Completed Features

### 1. Metadata Display (formerly Priority 1)
- **Native moOde indicator** (`sendspin-display.js`) uses moOde's built-in `#inpsrc-indicator` element
  - No custom overlay HTML, no custom CSS added to moOde
  - Matches AirPlay/Spotify/Deezer display pattern exactly
  - Covers full page with album art backdrop, metadata text, Turn Off button
- Polls `/command/renderer.php?cmd=get_sendspinmeta` every 3 seconds
- Shows cover art, title, artist, album on the main playback page
- Auto-hides when streaming stops
- Only activates on main page (`/` or `/index.php`) — never on config pages
- **Data source:** Home Assistant REST API polling via `sendspin-metadata-sink.py` daemon
  - Polls HA every 3 seconds for `media_player.moode_sendspin` state
  - Downloads and caches cover art locally
  - Always writes metadata on every poll (resilient to race conditions)
  - Workaround for Music Assistant's missing `metadata@v1` server-side implementation

### 2. Version Check and Update Button (was Priority 5)
- **Config page** (`ssp-config.php`) shows installed and latest available versions
- PyPI JSON API check (cached for 1 hour)
- One-click update via `uv tool upgrade sendspin` (background, non-blocking)
- Service restarts automatically after update

### 3. Audio Format Configuration
- Codec: FLAC or PCM (whitelisted)
- Sample rate: 44100, 48000, 96000 Hz
- Bit depth: 16, 24, 32 bit
- Config saved to `cfg_sendspin` DB table
- Service file regenerated dynamically on save via `generateSendspinService()`

### 4. Service Lifecycle
- `sendspin-spspre.sh` — pre-start hook that writes ALSA config with dynamic cardnum, sets active state
- `sendspin.service` — systemd unit with Restart=on-failure, real-time priority
- Service file regeneration from DB (survives reboot)
- **No hook scripts** on stream start/stop — HA metadata-sink handles everything independently
- `spspost.sh` simplified to stub — metadata cleanup handled by HA sink

### 5. Session Handling
- Stored session ID restored before `phpSession('open')` — works in incognito/no-cookie
- All session variables have defaults
- `Resume MPD` toggle (`rsmafterss`) — user-controlled MPD auto-resume

### 6. Dynamic ALSA Device Support
- ALSA card number read from DB, not hardcoded
- Works with any USB DAC on any card number
- ALSA config regenerated on every service start

## Deferred / Not Implemented

### CamillaDSP Loopback Support (was Priority 3)
- **Status:** Deferred indefinitely
- **Reason:** CamillaDSP operates downstream of the ALSA plug layer. SendSpin audio flows through `sendspin → plughw → DAC`, and CamillaDSP processes audio after that point. It works transparently without any SendSpin-specific code. The only exception is Bluetooth, which has a CDSP maxvol setting due to Bluetooth's unique volume path — SendSpin does not share this issue.

### Buffer Tuning for Sync Precision (was Priority 4)
- **Status:** Deferred
- **Reason:** Music Assistant handles network-layer synchronisation. SendSpin's `--static-delay-ms` (0–500ms) is available in the service file for manual tuning if needed. The default ALSA buffer settings are sufficient for reliable playback.

### Service Hardening / Non-Root Execution (was Priority 6)
- **Status:** Not started
- **Reason:** The service runs as root to access `sendspin` binary in `/root/.local/` and `systemctl` operations. This is consistent with moOde's existing architecture (most services run as root). A dedicated `moodeaudio` user setup would be a separate improvement.

### Volume Sync with Music Assistant
- **Status:** Not started
- **Reason:** `--hardware-volume false` delegates volume to software control in the SendSpin daemon. Music Assistant's volume slider controls the SendSpin output level through this channel. Hardware volume mixers are not supported by the SMSL DAC.

## Future Considerations

- **Upgrade path for moOde 10:** The installer handles re-patching after a moOde update. Documentation covers this.
- **PR to upstream moOde:** `SENDSPIN_PR.md` documents all changes for maintainer review.
