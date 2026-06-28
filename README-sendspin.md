# SendSpin Multi-Room Audio for moOde

SendSpin is a synchronized multi-room audio receiver. This integration adds SendSpin as a full renderer in moOde's web UI, on par with AirPlay, Spotify, Bluetooth, and other existing renderers.

## Features

- **ON/OFF toggle** with auto-save in the Renderers page
- **Resume MPD** — optionally resume MPD playback after SendSpin disconnects
- **Config page** — configure audio format (codec/sample rate/bit depth), log level
- **Version info** — displays installed version and latest available on PyPI (cached hourly)
- **Update button** — upgrades SendSpin CLI in the background
- **Metadata overlay** — shows cover art, title, artist, album using moOde's built-in `#inpsrc-indicator` (same element used by AirPlay/Spotify)
- **Dynamic ALSA support** — works with any ALSA card number, set in moOde's audio config
- **Software volume** — applies volume digitally when the DAC has no hardware mixer
- **Auto-start on boot** — via systemd service
- **Status detection** — shows active/inactive/streaming

## Requirements

- moOde 9.x or later
- Raspberry Pi 3/4/5 or compatible
- [SendSpin CLI](https://pypi.org/project/sendspin/) installed via `uv tool install sendspin`
- Network connection to a SendSpin server (e.g., Music Assistant)
- Home Assistant (optional — for metadata display via HA polling)

## Key Design Decisions

1. **No custom overlay HTML/CSS** — The metadata display uses moOde's built-in `#inpsrc-indicator` element (already in `header.php`), matching AirPlay/Spotify/Deezer display pattern exactly. Zero additional HTML/CSS footprint.
2. **No hook scripts on stream start/stop** — The HA polling daemon (`sendspin-metadata-sink.py`) handles all metadata independently, eliminating race conditions. The service file has no `--hook-start`/`--hook-stop` flags.
3. **No modification to playerlib.js** — `sendspinactive` FECmd is unused. The frontend JS polls the metadata API directly instead.

## Installer

**`moode-sendspin-installer.sh`** — Full-featured installer with backup, uninstall, 14-component detection, and all features

### Installation

```bash
git clone https://github.com/kiwipaulrob/moode.git
cd moode
git checkout sendspin-advanced
sudo bash moode-sendspin-installer.sh
```

The installer auto-detects the PHP version, creates all necessary files, configures the database, enables the systemd services, and creates a timestamped backup of all modified files.

### Install from URL

```bash
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-advanced/moode-sendspin-installer.sh | sudo bash
```

### Command Line Options

| Option | Description |
|--------|-------------|
| *(no flag)* | Full install — all features, config page, metadata overlay |
| `--minimal` | Minimal install — ON/OFF toggle + Resume MPD only (no config page) |
| `--check` | Check current installation status of all components |
| `--uninstall` | Uninstall — restores original moOde files from the most recent backup |
| `--no-backup` | Skip creating backup (for testing) |

Examples:

```bash
# Minimal install
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-advanced/moode-sendspin-installer.sh | sudo bash -s -- --minimal

# Check status
sudo bash moode-sendspin-installer.sh --check

# Uninstall
sudo bash moode-sendspin-installer.sh --uninstall
```

### Running from moOde's Built-in SSH Terminal

moOde has a built-in SSH terminal (System → SSH Terminal). You can run the installer directly from there:

1. Open moOde web UI → System → SSH Terminal
2. Paste the commands above
3. Enter your password when prompted

## Backup System

Before modifying any moOde file, the installer creates a **timestamped backup** at `/var/backups/moode-sendspin-YYYYMMDD-HHMMSS/`. Files backed up include:

- `moode-sqlite3.db` — Database snapshot before schema changes
- `sendspin.service` — Original systemd unit
- `constants.php`, `renderer.php` — Original PHP files
- `ren-config.php`, `ren-config.html` — Original renderers page
- `worker.php` — Original worker daemon
- `lib.min.js` — Original JS library

The `--uninstall` command finds the **most recent** backup and restores all files, making uninstallation safe and reversible.

### Related Backup Utilities

- [**kiwipaulrob/moode-tools**](https://github.com/kiwipaulrob/moode-tools) — Backup and restore utilities for moOde (includes scripts for database snapshots, config bundling, and system state recovery)

## What the Installer Does

| Component | File |
|-----------|------|
| Feature bitmask | `inc/constants.php` — adds `FEAT_SENDSPIN` (bit 18) |
| Lifecycle functions | `inc/renderer.php` — adds `startSendspin()`, `stopSendspin()`, `getSendspinStatus()`, `getSendspinVersion()`, `updateSendspin()`, `generateSendspinService()` |
| Renderers page controller | `ren-config.php` — POST handlers, session variables |
| Renderers page template | `templates/ren-config.html` — SendSpin section |
| Dedicated config page | `ssp-config.php` + `templates/ssp-config.html` |
| Worker job handlers | `daemon/worker.php` — `sendspinsvc`, `sendspinrestart` cases |
| Metadata overlay | `js/sendspin-display.js` — uses native `#inpsrc-indicator` (no custom HTML/CSS) |
| Pre-start hook | `commandw/sendspin-spspre.sh` — writes ALSA config dynamically |
| Systemd service | `/etc/systemd/system/sendspin.service` |
| ALSA device config | `/etc/alsa/conf.d/sendspin.conf` — regenerated dynamically |
| Database | `cfg_sendspin` table (audio format, log level) + session vars |
| Backup | `/var/backups/moode-sendspin-*/` — timestamped backup of all modified files |

## Database Schema

### Session Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `sendspinsvc` | `0` | Service ON/OFF |
| `sendspinname` | `moode-sendspin` | Endpoint name |
| `sendspin_installed` | `yes` | Installation flag |
| `mpd_was_playing` | `0` | MPD state before SendSpin start |
| `rsmafterss` | `No` | Resume MPD after disconnect |

### `cfg_sendspin` Table

| Parameter | Default | Values |
|-----------|---------|--------|
| `audio_codec` | `flac` | flac, pcm |
| `audio_rate` | `48000` | 44100, 48000, 96000 |
| `audio_depth` | `16` | 16, 24, 32 |
| `static_delay_ms` | `0` | 0–500 |
| `log_level` | `INFO` | DEBUG, INFO, WARNING, ERROR |

## Usage

1. Open moOde → Configure → Renderers
2. Find the **SendSpin** section
3. Set a **Name** (appears in your multi-room controller)
4. Toggle **Service** ON
5. (Optional) Toggle **Resume MPD** to restore MPD playback after SendSpin disconnects
6. Click the **Edit** button for advanced settings (audio format, log level)

Your SendSpin endpoint appears automatically via mDNS on your network. Controllers like Music Assistant discover it without additional configuration.

## Post-Install: moOde Updates

If you update moOde (via System → Check for Update), core files are replaced with stock moOde versions. Re-run the installer afterward:

```bash
cd moode && git pull && sudo bash moode-sendspin-installer.sh
```

Database settings and custom files (config page, metadata overlay) survive the update and do not need to be reconfigured. The backup system preserves the previous state in case you need to roll back.

## Uninstall

```bash
sudo bash moode-sendspin-installer.sh --uninstall
```

Restores original moOde files from the most recent backup at `/var/backups/moode-sendspin-*/`. Also removes systemd service files, ALSA config, and the `cfg_sendspin` database table. Backups are preserved after uninstall so you can re-install later.

## Check Status

```bash
sudo bash moode-sendspin-installer.sh --check
```

Shows which components are installed and their status.

## Files

All integration code is on the `sendspin-advanced` branch of:
`https://github.com/kiwipaulrob/moode.git`

Key documents:
- `SENDSPIN_PR.md` — Design document for moOde maintainer review (includes CLI commands, backup system)
- `SENDSPIN_RELEASE2_ROADMAP.md` — Feature status and deferred items
- `README-sendspin.md` — This file
