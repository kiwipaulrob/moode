# SendSpin Multi-Room Audio Client for moOde

## Overview

SendSpin is an open-source, synchronized multi-room audio receiver. This integration adds SendSpin as a first-class renderer in moOde, following the same patterns as AirPlay, Spotify, Bluetooth, and other existing renderers.

**What it does:** Allows moOde to appear as an audio endpoint in multi-room systems (Music Assistant, etc.) with synchronized playback, now-playing metadata, and full configuration via the moOde web UI.

## Architecture — Minimal Overlay Approach

Unlike earlier iterations that used a custom full-page overlay (extra HTML, CSS, JS), the current implementation uses **no custom overlay HTML or CSS**. Instead it relies entirely on moOde's built-in `#inpsrc-indicator` element (already present in `header.php`), which is the same element used by AirPlay, Spotify, and Deezer for their renderer-active displays.

The frontend JS (`sendspin-display.js`) polls the metadata API and populates the native `#inpsrc-indicator` directly — same visual result as moOde's built-in renderers, zero additional HTML/CSS footprint.

## Files Changed

### New Files Created

| File | Purpose |
|------|---------|
| `inc/constants.php` | `FEAT_SENDSPIN` bitmask constant (bit 18 = 262144), `SENDSPINMETA_FILE` constant |
| `inc/renderer.php` | `startSendspin()`, `stopSendspin()`, `getSendspinStatus()`, `getSendspinVersion()`, `updateSendspin()`, `generateSendspinService()`, `getSendspinMetadata()`, `checkSendspinUpdate()` |
| `templates/ssp-config.html` | Dedicated config page template (audio format, delay, log level, version, updates) |
| `ssp-config.php` | Config page controller with save handler, PyPI version check (cached 1 hour), service regeneration |
| `commandw/sendspin-spspre.sh` | Pre-start hook — writes ALSA config with dynamic card number from DB, sets sendspinactive state |
| `js/sendspin-display.js` | Frontend JS — polls metadata API every 3s, populates moOde's built-in `#inpsrc-indicator` (no custom overlay) |
| `etc/systemd/system/sendspin.service` | SendSpin daemon — Restart=on-failure, real-time priority, no hook scripts |
| `etc/alsa/conf.d/sendspin.conf` | ALSA plug device configuration (regenerated dynamically with correct card number) |
| `hooks/sendspin-metadata.sh` | Stub (10 lines) — metadata handled by HA polling daemon |
| `hooks/spspost.sh` | Stub (10 lines) — cleanup handled by HA polling daemon |

### Modified Files

| File | Changes |
|------|---------|
| `ren-config.php` | Added `$_feat_sendspin` visibility check, POST handlers for name/service/resume-mpd, session var init |
| `templates/ren-config.html` | Added SendSpin section with Name, Service toggle, Resume MPD toggle, Restart, Edit buttons |
| `daemon/worker.php` | Added `sendspinsvc` and `sendspinrestart` job handlers, startup detection, lifecycle logging |
| `command/renderer.php` | Added `get_sendspinmeta` endpoint (reads `/var/local/www/sendspinmeta.txt`) |
| `footer.php` | Added `<script src="sendspin-display.js">` before `<?php` — only extra line in moOde HTML |
| `moode-sendspin-r2-installer.sh` | Service template updated (no hook flags) |

### Files NOT Modified (uses existing moOde infrastructure)

| Element | Used for |
|---------|----------|
| `header.php` | `#inpsrc-indicator` already in every page — no changes needed |
| `styles.min.css` | All `#inpsrc-*` CSS already present — no changes needed |
| `footer.min.php` on Pi | Only the `<script>` tag was added — no custom overlay HTML |
| `main.min.js` (playerlib.js) | Not modified — `sendspinactive` FECmd not needed since our JS polls directly |

## Database Schema

### New Session Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `sendspinsvc` | `0` | Service ON/OFF toggle |
| `sendspinname` | `moode-sendspin` | Endpoint name visible in controllers |
| `sendspin_installed` | `yes` | Installation flag |
| `mpd_was_playing` | `0` | MPD state before SendSpin start |
| `rsmafterss` | `No` | Resume MPD after SendSpin disconnect |

### New Database Tables

**`cfg_sendspin`** — Stores SendSpin audio configuration:

| Column | Type | Purpose |
|--------|------|---------|
| `param` | CHAR(32) | Setting name (`audio_codec`, `audio_rate`, `audio_depth`, `static_delay_ms`, `log_level`) |
| `value` | CHAR(128) | Setting value |

### Feature Bitmask

```php
define('FEAT_SENDSPIN', 262144); // bit 18
```

Stored in `cfg_system.feat_bitmask`. OR'd with existing bitmask. Does not conflict with any existing feature bits.

## Architecture

### Metadata Display

The metadata pipeline is:

```
Home Assistant → sendspin-metadata-sink.py (polls every 3s)
    → writes /var/local/www/sendspinmeta.txt (~~~ delimited format)
    → command/renderer.php?cmd=get_sendspinmeta (PHP reads file)
    → sendspin-display.js (polls every 3s)
    → populates #inpsrc-indicator, #inpsrc-cover, #inpsrc-metadata (native moOde elements)
```

Key design decisions:
1. **No hook scripts** on stream start/stop — HA polling daemon handles independently
2. **No custom overlay HTML/CSS** — uses moOde's built-in `#inpsrc-indicator`
3. **No modification to playerlib.js/main.min.js** — `sendspinactive` FECmd is unused
4. **Always writes on every poll** — resilient to race conditions from any source
5. **Only activates on main page** (`/` or `/index.php`) — never affects config pages

### Service File

The systemd service file is dynamically generated from the `cfg_sendspin` database table on each config save. This means:
- Audio format, delay, and log level changes take effect on next service restart
- No manual editing of systemd unit files required
- The ALSA config (`/etc/alsa/conf.d/sendspin.conf`) is also regenerated with the correct card number

### Remove `--hook-start` / `--hook-stop`

The service file no longer includes `--hook-start` or `--hook-stop` flags. The HA metadata-sink daemon (`sendspin-metadata-sink.py`) handles all metadata independently via direct HA API polling. This eliminates the race condition where hooks would overwrite real metadata with placeholder "Streaming" text on every stream start.

## Dependencies

**Runtime (installed separately, not bundled with moOde):**
- `sendspin` CLI (installed via `uv tool install sendspin`)
- `uv` Python package manager (installed via `pip3 install uv`)
- Home Assistant (optional — for metadata display via HA polling)

**No new PHP extensions or libraries required.** All code uses existing moOde infrastructure.

## Code Quality

- **Input validation** on all config values (codec, rate, depth, delay, log_level whitelisted)
- **Error handling** — systemd units have `Restart=on-failure`
- **No PHP notices/warnings** in normal operation
- **Follows moOde conventions** — same template engine (`echoTemplate`), same session pattern (`phpSession`), same UI pattern (config-help-info, toggle-radio, config-btn)

## Installation

```bash
git clone https://github.com/kiwipaulrob/moode.git
cd moode
git checkout sendspin-advanced
sudo bash moode-sendspin-installer.sh
```

The installer auto-detects the PHP version, creates all necessary files, configures the database, and enables the systemd services.

## PR Integration Notes for Maintainer

### Minimal PR Surface

If you want the smallest possible integration, you can omit:

1. **`ssp-config.php` and `templates/ssp-config.html`** — The basic SendSpin controls (ON/OFF, Name, Resume MPD, Restart) work without the dedicated config page
2. **`sendspin-display.js`** — The metadata overlay is optional; the renderer works without it
3. **`sendspin-metadata-sink.py` and `.service`** — The HA polling daemon is optional; metadata display uses no custom HTML/CSS

Minimum required files:
- `inc/constants.php` (one constant line + one file path constant)
- `inc/renderer.php` (lifecycle functions)
- `ren-config.php` (handler + session vars)
- `templates/ren-config.html` (UI section)
- `daemon/worker.php` (job handlers)
- Database entries (`sendspinsvc`, `sendspinname`, `sendspin_installed`, `rsmafterss`)
- Systemd service file for sendspin daemon

### Backward Compatibility

- **No existing moOde features are affected** — SendSpin is registered via its own feature bit (18)
- **No existing session variables are modified** — all new vars have unique names
- **No existing database tables are modified** — `cfg_sendspin` is a new table
- **No moOde core HTML/CSS/JS modified** — only `footer.php` has one extra `<script>` line
- **Existing renderers continue to work unchanged** — the ALSA device arbitration is handled by the user enabling/disabling renderers

### Testing Performed

- HTTP 200 on all configured pages
- PHP syntax check on all modified files
- Session handling tested with and without cookies (incognito mode)
- Service file regeneration tested with all audio format combinations
- ALSA config verified with different card numbers
- MPD coexistence tested (stop/resume cycle)
- Metadata overlay tested with active and stopped streams (browser verified)
- Cover art download and caching verified
- No hook warnings in sendspin journal (stream starts/stops clean)
