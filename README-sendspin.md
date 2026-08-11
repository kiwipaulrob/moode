# SendSpin Multi-Room Audio for moOde

SendSpin is a synchronized multi-room audio receiver. This integration adds SendSpin as a full renderer in moOde's web UI, on par with AirPlay, Spotify, Bluetooth, and other existing renderers.

## Features

- **ON/OFF toggle** with auto-save in the Renderers page
- **Resume MPD** — optionally resume MPD playback after SendSpin disconnects
- **Config page** — configure audio format (codec/sample rate/bit depth), log level
- **Version info** — displays installed version and latest available on PyPI (cached hourly)
- **Update button** — upgrades SendSpin CLI in the background
- **Metadata overlay** — shows cover art, title, artist, album using moOde's built-in `#inpsrc-indicator` (same element used by AirPlay/Spotify)
- **Native volume** — uses moOde's `_audioout` ALSA device (same as AirPlay, Spotify, MPD); volume knob works natively
- **Auto-start on boot** — honors the Renderers-page toggle (worker.php boot-time startup block; systemd service enabled)
- **Status detection** — shows active/inactive/streaming

## Requirements

- moOde 9.x or later (tested through r1033 / moOde 10.3.2)
- Raspberry Pi 3/4/5
- Network connection to a SendSpin server (e.g., Music Assistant)
- Home Assistant (optional — for metadata display via HA polling)

The installer automatically installs Python 3, `uv` (Python package manager), and the `sendspin` CLI — no manual prerequisite installation is needed.

## Key Design Decisions

1. **No custom overlay HTML/CSS** — The metadata display uses moOde's built-in `#inpsrc-indicator` element (already in `header.php`), matching AirPlay/Spotify/Deezer display pattern exactly. Zero additional HTML/CSS footprint.
2. **Uses moOde's `_audioout` device** — Same ALSA path as AirPlay, Spotify, MPD. No separate ALSA config needed. Volume knob works natively without attenuation hacks.
3. **No modification to playerlib.js** — `sendspinactive` FECmd is unused. The frontend JS polls the metadata API directly instead.
4. **Stop/start matches other renderers** — Calls `vol.sh -restore`, CamillaDSP volume sync, and `sendFECmd('sspactive0')` on stop, exactly like AirPlay/Spotify/RoonBridge.

## Installer

**`moode-sendspin-installer.sh`** — Full-featured installer with backup, uninstall, 19-component detection, and all features. **Current version: v4.1.4** (moOde 10.3.2 / r1033 support; idempotent re-runs — safe to run repeatedly, no duplicate DB rows; partial installations detected and repaired automatically; boot-time auto-start honors the UI toggle).

### Installation

```bash
git clone https://github.com/kiwipaulrob/moode.git
cd moode
git checkout sendspin-advanced
sudo bash moode-sendspin-installer.sh
```

The installer auto-detects the PHP version and automatically installs Python 3, `uv`, and the `sendspin` CLI if not already present. It then creates all necessary files, configures the database, enables systemd services, and creates a timestamped backup of all modified files.

### Install from URL

```bash
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-advanced/moode-sendspin-installer.sh | sudo bash
```

### Command Line Options

| Option | Description |
|--------|-------------|
| *(no flag)* | Full install — all features, config page, metadata overlay |
| `--minimal` | Minimal install — ON/OFF toggle + Resume MPD only (no config page) |
| `--check` | Check current installation status of all components (flags partial installs) |
| `--uninstall` | Uninstall — restores original moOde files from the most recent backup |
| `--force` | Skip all confirmation prompts (for automated/scripted installs) |
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
| Worker job handlers + boot startup | `daemon/worker.php` — `sendspinsvc`, `sendspinrestart` cases plus a boot-time startup block that honors the UI toggle |
| Metadata overlay | `js/sendspin-display.js` — uses native `#inpsrc-indicator` (no custom HTML/CSS) |
| Pre-start hook | `commandw/sendspin-spspre.sh` — validates `_audioout` device |
| Systemd service | `/etc/systemd/system/sendspin.service` — uses `_audioout`, same device as AirPlay/Spotify/MPD |
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
| `log_level` | `INFO` | DEBUG, INFO, WARNING, ERROR |

## Usage

The installer deploys files but does NOT start the SendSpin service automatically.
After installation:

1. Restart PHP: `sudo systemctl restart php*-fpm`
2. Open moOde web UI → Configure → Renderers
3. Find the **SendSpin** section
4. Toggle **Service** ON and click the save arrow
5. Toggle **Resume MPD** if desired (restores MPD after SendSpin stops)
6. Click **Edit** for advanced settings (audio format, log level, updates)

Your SendSpin endpoint appears automatically via mDNS on your network. Controllers like Music Assistant discover it without additional configuration.

## Post-Install: moOde Updates

If you update moOde (via System → Check for Update), core files are replaced with stock moOde versions. Re-run the installer afterward:

```bash
cd moode && git pull && sudo bash moode-sendspin-installer.sh
```

The installer detects partial installations (components missing after a moOde update) and reinstalls **only** the missing components — including re-patching `worker.php` and repairing the boot-time startup block. Re-running is safe and idempotent: database settings and custom files (config page, metadata overlay) survive and are never duplicated or reset.

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
