# SendSpin Multi-Room Audio for moOde

SendSpin is a synchronized multi-room audio receiver. This integration adds SendSpin as a full renderer in moOde's web UI, on par with AirPlay, Spotify, Bluetooth, and other existing renderers.

## Features

- **ON/OFF toggle** with auto-save in the Renderers page
- **Resume MPD** — optionally resume MPD playback after SendSpin disconnects
- **Config page** — configure audio format (codec/sample rate/bit depth), log level
- **Version info** — displays installed version and latest available on PyPI (cached hourly)
- **Update button** — upgrades SendSpin CLI in the background
- **Metadata overlay** — shows cover art, title, artist, album on the main playback page
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

## Quick Install

```bash
git clone https://github.com/kiwipaulrob/moode.git
cd moode
git checkout sendspin-advanced
sudo bash moode-sendspin-installer.sh
```

The installer automatically installs Python 3, `uv`, and `sendspin` CLI if they are not already present.

## What the Installer Does

| Component | File |
|-----------|------|
| Feature bitmask | `inc/constants.php` — adds `FEAT_SENDSPIN` (bit 18) |
| Lifecycle functions | `inc/renderer.php` — adds `startSendspin()`, `stopSendspin()`, `getSendspinStatus()`, `getSendspinVersion()`, `updateSendspin()`, `generateSendspinService()` |
| Renderers page controller | `ren-config.php` — POST handlers, session variables |
| Renderers page template | `templates/ren-config.html` — SendSpin section |
| Dedicated config page | `ssp-config.php` + `templates/ssp-config.html` |
| Worker job handlers | `daemon/worker.php` — `sendspinsvc`, `sendspinrestart` cases |
| Metadata overlay | `js/sendspin-display.js` |
| Pre-start hook | `commandw/sendspin-spspre.sh` — writes ALSA config dynamically |
| Systemd service | `/etc/systemd/system/sendspin.service` |
| MoOde worker service | `/etc/systemd/system/moode-worker.service` (replaces rc.local) |
| ALSA device config | `/etc/alsa/conf.d/sendspin.conf` — regenerated dynamically |
| Database | `cfg_sendspin` table (audio format, log level) + session vars |

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

Database settings and custom files (config page, metadata overlay) survive the update and do not need to be reconfigured.

## Uninstall

```bash
sudo bash moode-sendspin-installer.sh --uninstall
```

Restores original moOde files from backup.

## Check Status

```bash
sudo bash moode-sendspin-installer.sh --check
```

Shows which components are installed (11 total).

## Files

All integration code is on the `sendspin-advanced` branch of:
`https://github.com/kiwipaulrob/moode.git`

Key documents:
- `SENDSPIN_PR.md` — Design document for moOde maintainer review
- `SENDSPIN_CODE_REVIEW.md` — Code audit with all identified issues
- `README-sendspin.md` — This file
- `setup_3rdparty_sendspin.txt` — Setup guide (on-device)
