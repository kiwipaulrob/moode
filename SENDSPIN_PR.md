# SendSpin Multi-Room Audio Client for moOde

## Overview

SendSpin is an open-source, synchronized multi-room audio receiver. This integration adds SendSpin as a first-class renderer in moOde, following the same patterns as AirPlay, Spotify, Bluetooth, and other existing renderers.

**What it does:** Allows moOde to appear as an audio endpoint in multi-room systems (Music Assistant, etc.) with synchronized playback, now-playing metadata, and full configuration via the moOde web UI.

## Files Changed

### New Files Created

| File | Purpose |
|------|---------|
| `inc/constants.php` | `FEAT_SENDSPIN` bitmask constant (bit 18 = 262144) |
| `inc/renderer.php` | `startSendspin()`, `stopSendspin()`, `getSendspinStatus()`, `getSendspinVersion()`, `updateSendspin()`, `generateSendspinService()` |
| `templates/ssp-config.html` | Dedicated config page template (audio format, delay, log level, version, updates) |
| `ssp-config.php` | Config page controller with save handler, PyPI version check, service regeneration |
| `js/sendspin-display.js` | Frontend overlay for now-playing metadata display |
| `setup_3rdparty_sendspin.txt` | Setup guide for end users |
| `etc/systemd/system/sendspin.service` | SendSpin daemon systemd unit |
| `etc/systemd/system/moode-worker.service` | Worker daemon (replaces rc.local for renderer lifecycle) |
| `etc/alsa/conf.d/sendspin.conf` | ALSA plug device configuration |
| Various hooks | Pre/post start scripts (`spspre.sh`, `spspost.sh`), metadata hooks |

### Modified Files

| File | Changes |
|------|---------|
| `ren-config.php` | Added `$_feat_sendspin` visibility check, POST handlers for name/service/resume-mpd, session var init |
| `templates/ren-config.html` | Added SendSpin section with Name, Service toggle, Resume MPD toggle, Restart, Edit buttons |
| `daemon/worker.php` | Added `sendspinsvc` and `sendspinrestart` job handlers, startup detection, lifecycle logging |
| `footer.min.php` | No changes — sendspin-display.js loaded via existing include mechanism in the SendSpin section |

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

### Renderer Lifecycle

```
User toggle ON → ren-config.php POST handler
                → submitJob('sendspinsvc')
                → worker.php dispatches
                → startSendspin()
                    → save MPD state
                    → mpc stop (release ALSA)
                    → systemctl start sendspin

User toggle OFF → ren-config.php POST handler
                → submitJob('sendspinsvc')
                → worker.php dispatches
                → stopSendspin()
                    → systemctl stop sendspin
                    → resume MPD if rsmafterss=Yes
```

### Service File Generation

The systemd service file is dynamically generated from the `cfg_sendspin` database table on each config save. This means:

- Audio format, delay, and log level changes take effect on next service restart
- No manual editing of systemd unit files required
- The ALSA config (`/etc/alsa/conf.d/sendspin.conf`) is also regenerated with the correct card number

### Metadata Display

When streaming, a frontend overlay shows cover art, title, artist, and album on the main playback page. The overlay:

- Polls `/var/local/www/sendspinmeta.txt` every 2 seconds
- Only activates on the main playback page (`/` or `/index.php`)
- Never displays on config pages
- Auto-hides when streaming stops

## Dependencies

**Runtime (installed separately, not bundled with moOde):**
- `sendspin` CLI (installed via `uv tool install sendspin`)
- `uv` Python package manager (installed via `pip3 install uv`)

**No new PHP extensions or libraries required.** All code uses existing moOde infrastructure.

## Code Quality

- **All 20 identified issues documented and tracked** in `SENDSPIN_CODE_REVIEW.md`
- **9 critical bugs fixed** including: session handling for incognito/empty sessions, double SQLite connect deadlock, typo `tsysCmd`, service restart on save, ALSA card number dynamic resolution
- **Input validation** on all config values (codec, rate, depth, delay, log_level whitelisted)
- **Error handling** — systemd units have `Restart=on-failure`, temp file writes use `@` suppression
- **No PHP notices/warnings** in normal operation
- **Follows moOde conventions** — same template engine (`echoTemplate`), same session pattern (`phpSession`), same UI pattern (config-help-info, toggle-radio, config-btn)

## Installation

```bash
sudo bash moode-sendspin-installer.sh
```

The installer auto-detects the PHP version, creates all necessary files, configures the database, and enables the systemd services.

## Uninstallation

```bash
sudo bash moode-sendspin-installer.sh --uninstall
```

Restores original moOde files from backup.

## PR Integration Notes for Maintainer

### Minimal PR Surface

If you want the smallest possible integration, you can omit:

1. **`ssp-config.php` and `templates/ssp-config.html`** — The basic SendSpin controls (ON/OFF, Name, Resume MPD, Restart) work without the dedicated config page
2. **`js/sendspin-display.js`** — The metadata overlay is optional; the renderer works without it
3. **`sendspin-metadata-sink.py`** — The HA polling daemon is optional; metadata can be provided by the SendSpin protocol directly
4. **`moode-worker.service`** — The existing `rc.local` mechanism can be used instead

Minimum required files:
- `inc/constants.php` (one constant line)
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
- **Existing renderers continue to work unchanged** — the ALSA device arbitration is handled by the user enabling/disabling renderers

### Testing Performed

- HTTP 200 on all configured pages
- PHP syntax check on all modified files
- Session handling tested with and without cookies (incognito mode)
- Service file regeneration tested with all audio format combinations
- ALSA config verified with different card numbers
- MPD coexistence tested (stop/resume cycle)
- Metadata overlay tested with active and stopped streams
- PyPI version check tested with cached and uncached states
- Uninstall/clean removal tested
