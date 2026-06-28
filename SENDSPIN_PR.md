# SendSpin Multi-Room Audio Client for moOde

## Overview

SendSpin is an open-source, synchronized multi-room audio receiver. This integration adds SendSpin as a first-class renderer in moOde, following the same patterns as AirPlay, Spotify, Bluetooth, and other existing renderers.

**What it does:** Allows moOde to appear as an audio endpoint in multi-room systems (Music Assistant, etc.) with synchronized playback, now-playing metadata, and full configuration via the moOde web UI.

## Architecture — Minimal Overlay Approach

Unlike earlier iterations that used a custom full-page overlay (extra HTML, CSS, JS), the current implementation uses **no custom overlay HTML or CSS**. Instead it relies entirely on moOde's built-in `#inpsrc-indicator` element (already present in `header.php`), which is the same element used by AirPlay, Spotify, and Deezer for their renderer-active displays.

The frontend JS (`sendspin-display.js`) polls the metadata API and populates the native `#inpsrc-indicator` directly — same visual result as moOde's built-in renderers, zero additional HTML/CSS footprint.

## Installer

**`moode-sendspin-installer.sh`** — Full-featured installer with backup, uninstall, 14-component detection, and commandw script deployment.

### Command Line Options

```bash
# Full install (default) — all features, config page, metadata overlay
sudo bash moode-sendspin-installer.sh

# Install from URL without downloading first
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-advanced/moode-sendspin-installer.sh | sudo bash

# Minimal install — ON/OFF toggle + Resume MPD only (no config page)
sudo bash moode-sendspin-installer.sh --minimal
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-advanced/moode-sendspin-installer.sh | sudo bash -s -- --minimal

# Check current installation status
sudo bash moode-sendspin-installer.sh --check

# Uninstall — restores original moOde files from backup
sudo bash moode-sendspin-installer.sh --uninstall

# Skip backup (for testing)
sudo bash moode-sendspin-installer.sh --no-backup
```

### Backup System

Before modifying any moOde file, the installer creates a **timestamped backup** at `/var/backups/moode-sendspin-YYYYMMDD-HHMMSS/`. Backed up files include:

- `moode-sqlite3.db` — Database snapshot before schema changes
- `sendspin.service` — Original systemd unit
- `constants.php`, `renderer.php` — Original PHP files
- `ren-config.php`, `ren-config.html` — Original renderers page
- `worker.php` — Original worker daemon
- `lib.min.js` — Original JS library
- `sendspin-spspre.sh`, `sendspin-metadata.sh`, `spspost.sh`, `sendspin-version-check.sh` — Lifecycle scripts

The `--uninstall` command finds the **most recent** backup and restores all original files. This makes uninstallation safe and reversible.

To manually create a backup without installing:
```bash
# The backup is created automatically during install.
# To preserve a specific state, you can also run:
mkdir -p /var/backups/moode-sendspin-manual/
cp /var/local/www/db/moode-sqlite3.db /var/backups/moode-sendspin-manual/
```

### Related Backup Utilities

- [**kiwipaulrob/moode-tools**](https://github.com/kiwipaulrob/moode-tools) — Backup and restore utilities for moOde (includes scripts for database snapshots, config bundling, and system state recovery)

## Files Changed

### New Files Created

| File | Purpose |
|------|---------|
| `inc/constants.php` | `FEAT_SENDSPIN` bitmask constant (bit 18 = 262144), `SENDSPINMETA_FILE` constant |
| `inc/renderer.php` | `startSendspin()`, `stopSendspin()`, `getSendspinStatus()`, `getSendspinVersion()`, `updateSendspin()`, `generateSendspinService()`, `getSendspinMetadata()`, `checkSendspinUpdate()` |
| `templates/ssp-config.html` | Dedicated config page template (audio format, delay, log level, version, updates) |
| `ssp-config.php` | Config page controller with save handler, PyPI version check (cached 1 hour), service regeneration |
| `commandw/sendspin-spspre.sh` | Pre-start hook — validates ALSA config, clears stale metadata |
| `commandw/sendspin-metadata.sh` | Hook for start/stop — writes/clears metadata to `sendspinmeta.txt` |
| `commandw/spspost.sh` | Post-stop hook — cleanup, clear metadata, log device status |
| `commandw/sendspin-version-check.sh` | PyPI version check — returns JSON `{installed, latest, update_available}` |
| `js/sendspin-display.js` | Frontend JS — polls metadata API every 3s, populates moOde's built-in `#inpsrc-indicator` (no custom overlay) |
| `etc/systemd/system/sendspin.service` | SendSpin daemon — dynamically generated from `cfg_sendspin` DB, uses moOde's `_audioout` device for consistent volume with other renderers |
| `daemon/sendspin-metadata-sink.py` | HA-polling metadata sink daemon (optional — alternative to hook-based metadata) |

### Modified Files

| File | Changes |
|------|---------|
| `ren-config.php` | Added `$_feat_sendspin` visibility check, POST handlers for name/service/rsmafterss, calls `generateSendspinService($dbh)` on save (reuses existing `$dbh` connection), `require_once` moved to top |
| `templates/ren-config.html` | Added SendSpin section with Name, Service toggle, Resume MPD toggle, Restart, Edit — proper sibling of RoonBridge |
| `daemon/worker.php` | Added `sendspinsvc` and `sendspinrestart` job handlers, startup detection, lifecycle logging |
| `command/renderer.php` | Added `get_sendspinmeta` endpoint (reads `/var/local/www/sendspinmeta.txt`) |
| `footer.php` | Added `<script src=\"sendspin-display.js\">` before `<?php` — only extra line in moOde HTML |
| `moode-sendspin-installer.sh` | Backup system, uninstall, 14-component detection, commandw script deployment, service generation |

### Files NOT Modified (uses existing moOde infrastructure)

| Element | Used for |
|---------|----------|
| `header.php` | `#inpsrc-indicator` already in every page — no changes needed |
| `styles.min.css` | All `#inpsrc-*` CSS already present — no changes needed |
| `footer.min.php` on Pi | Only the `<script>` tag was added — no custom overlay HTML |
| `main.min.js` (playerlib.js) | Not modified — `sendspinactive` FECmd not needed since our JS polls directly |

## Database Schema

### New Session Variables / Database Entries

| Variable | Default | Purpose |
|----------|---------|---------|
| `sendspinsvc` | `0` | Service ON/OFF toggle |
| `sendspinname` | `moode-sendspin` | Endpoint name visible in controllers |
| `sendspin_installed` | `yes` | Installation flag |
| `rsmafterss` | `No` | Resume MPD after SendSpin disconnect (user-controlled) |
| `sendspin_mpd_was_playing` | `0` | MPD playback state before SendSpin started (persisted in DB for PHP-FPM restart resilience) |
| `mpd_was_playing` | `0` | PHP session mirror of above (fast path for normal operation) |

### New Database Tables

**`cfg_sendspin`** — Stores SendSpin audio configuration:

| Column | Type | Purpose |
|--------|------|---------|
| `param` | CHAR(32) | Setting name (`audio_codec`, `audio_rate`, `audio_depth`, `log_level`) |
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
1. **Hook-based metadata** — `--hook-start/--hook-stop` write metadata directly via `sendspin-metadata.sh`; HA sink daemon is an optional alternative
2. **No custom overlay HTML/CSS** — uses moOde's built-in `#inpsrc-indicator`
3. **No modification to playerlib.js/main.min.js** — `sendspinactive` FECmd is unused
4. **Always writes on every poll** — resilient to race conditions from any source
5. **Only activates on main page** (`/` or `/index.php`) — never affects config pages

### Service File Configuration

The systemd service file is dynamically generated from the `cfg_sendspin` database table on each config save. Key flags:

| Flag | Source | Default | Description |
|------|--------|---------|-------------|
| `--audio-device` | `_audioout` (moOde's shared ALSA device) | `_audioout` | Same device as AirPlay, Spotify, MPD — volume knob works natively |
| `--audio-format` | `audio_codec:audio_rate:audio_depth:2` | `flac:48000:16:2` | Codec, sample rate, bit depth, channels |
| `--log-level` | `log_level` (DEBUG/INFO/WARNING/ERROR) | `INFO` | Daemon log verbosity |
| `--hook-start` | `/var/local/www/commandw/sendspin-metadata.sh` | — | Writes metadata on stream start |
| `--hook-stop` | `/var/local/www/commandw/sendspin-metadata.sh` | — | Clears metadata on stream stop |
| `ExecStartPre` | `sendspin-spspre.sh` | — | Validates ALSA, clears stale state before daemon starts |
| `ExecStopPost` | `spspost.sh` | — | Cleans up metadata and logs device state after daemon stops |

Volume is managed by moOde's integrated volume system. Multi-room sync delay is handled by Music Assistant's network-layer synchronisation.

SendSpin uses moOde's standard `_audioout` ALSA device — the same device used by AirPlay, Spotify, RoonBridge, and MPD. On stop, `vol.sh -restore` restores the volume knob, and `sendFECmd('sspactive0')` notifies the frontend, exactly matching the pattern of all other renderers. No separate ALSA device or attenuation is needed.

## Dependencies

**Installed automatically by the installer — no manual setup required:**

- Python 3 (via `apt-get`)
- `uv` Python package manager (via `pip3 install uv`)
- `sendspin` CLI (via `uv tool install sendspin`)

**Optional:**
- Home Assistant (for metadata display via HA polling — hook-based metadata works standalone)

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

The installer auto-detects the PHP version, creates all necessary files, configures the database, enables the systemd services, and creates a timestamped backup of all modified files.

### Post-Install: moOde Updates

If you update moOde (via System → Check for Update), core files are replaced with stock versions. Re-run:

```bash
cd moode && git pull && sudo bash moode-sendspin-installer.sh
```

Database settings and custom files survive the update. The installer re-applies patches using the new moOde file versions as base.

## Uninstall

The `--uninstall` command restores all original moOde files from the most recent backup at `/var/backups/moode-sendspin-*/`. It also removes systemd service files, ALSA config, and the `cfg_sendspin` database table.

```bash
sudo bash moode-sendspin-installer.sh --uninstall
```

Backups are preserved after uninstall so you can re-install later.

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
- Install/uninstall cycle tested with backup and restore
