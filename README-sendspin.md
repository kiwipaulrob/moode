# SendSpin Integration - Minimal Install Documentation

## Branch Strategy

| Branch | Contents | Status |
|--------|----------|--------|
| `sendspin-integration` (Release 1) | Basic control UI | ✅ Complete |
| `sendspin-advanced` (Release 2) | Metadata, volume sync, update | 🆕 New |

---

## Minimal Install (Release 1) - What It Includes

### Files Modified/Installed

```
/var/www/inc/constants.php           → +FEAT_SENDSPIN constant
/var/www/inc/renderer.php            → +startSendspin(), stopSendspin(), getSendspinStatus()
/var/www/ren-config.php              → +POST handlers, session variables
/var/www/templates/ren-config.html   → +SendSpin section in Renderers
/var/www/daemon/worker.php           → +startup check, job handlers
/etc/systemd/system/sendspin.service → SendSpin daemon service
/etc/alsa/conf.d/sendspin.conf       → ALSA device configuration
/var/www/setup_3rdparty_sendspin.txt → Documentation

Database entries:
- sendspin_installed = 'yes'
- sendspinsvc = '0' or '1'
- sendspinname = 'Moode SendSpin'
```

### What Minimal Install Does

1. ✅ Shows SendSpin in Configure → Renderers
2. ✅ ON/OFF toggle with auto-save
3. ✅ Name field for custom endpoint name
4. ✅ Restart button with confirmation
5. ✅ Start/stops SendSpin daemon
6. ✅ Handles MPD coexistence (auto-stop/resume)
7. ✅ Manual control only - no metadata display

### Release 2 Complete Feature List

SendSpin for moOde now includes:

### Core Renderer (ren-config.php)
- ✅ ON/OFF toggle with auto-save
- ✅ Name field
- ✅ Resume MPD toggle (rsmafterss)
- ✅ Restart button with confirmation modal
- ✅ Edit button linking to settings page
- ✅ Start/stops SendSpin daemon via systemd
- ✅ Auto-start on boot (moode-worker.service)
- ✅ Status detection (active/inactive/streaming)

### Metadata Display
- ✅ Music Assistant HA polling
- ✅ Overlay with cover art, title, artist, album
- ✅ 2-second polling interval
- ✅ Auto-hide when playback stops
- ✅ Only on main page (not config pages)

### Config Page (ssp-config.php)
- ✅ Version display (installed + latest via PyPI, cached hourly)
- ✅ Update button (background uv tool upgrade)
- ✅ Audio format selector (codec: FLAC/PCM, rate: 44.1/48/96kHz, depth: 16/24/32)
- ✅ Static delay tuning (0-500ms)
- ✅ Log level selector (DEBUG/INFO/WARNING/ERROR)
- ✅ Dynamic ALSA device info (card number + device name)
- ✅ Volume mode info
- ✅ Save button with live service regeneration
- ✅ Help tooltips on all settings

### Service Management
- ✅ Systemd service with auto-restart
- ✅ Hardware volume disabled (software volume)
- ✅ ALSA config dynamic (supports any card number)
- ✅ Service file regeneration on config save
- ✅ Pre/post start hooks (spspre.sh, spspost.sh)
- ✅ MPD coexistence (auto-stop/resume with toggle)
- ✅ worker.php integration (lifecycle detection)

### GitHub Integration
- ✅ Code on sendspin-advanced branch
- ✅ Code review document (SENDSPIN_CODE_REVIEW.md)
- ✅ Installer script (moode-sendspin-installer.sh)
- ✅ README documentation

---

## How Minimal Install Interacts With Other moOde Providers

### Provider Hierarchy (moOde Architecture)

moOde has a **single audio output device** architecture. Only ONE renderer can use the audio device at a time:

```
┌─────────────────────────────────────────────────────────┐
│                    moOde System                          │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ MPD      │  │ AirPlay  │  │ Spotify  │  ... etc     │
│  │ (Local)  │  │ (Remote) │  │ (Remote) │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
│       │             │             │                      │
│       └─────────────┴─────────────┘                      │
│                     │                                    │
│              ┌──────┴──────┐                            │
│              │  _audioout   │ ← ALSA device              │
│              └─────────────┘                            │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### SendSpin in the Hierarchy

```
┌─────────────────────────────────────────────────────────┐
│              NEW: SendSpin Added                         │
│                                                          │
│  Renderers:                                              │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐       │
│  │ AirPlay │ │ Spotify │ │ Deezer  │ │SendSpin │ ← New  │
│  │ shairp- │ │ libre-  │ │ libres- │ │ daemon  │       │
│  │ ort-syn │ │ spot    │ │ pot     │ │         │       │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘       │
│       └───────────┴───────────┴───────────┘              │
│                     │                                    │
│              ┌──────┴──────┐                            │
│              │  _audioout   │ ← Single device           │
│              └─────────────┘                            │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Interaction Rules

| Scenario | Behavior |
|----------|----------|
| MPD playing + Enable SendSpin | MPD stops, SendSpin starts |
| SendSpin streaming + Disable SendSpin | SendSpin stops, MPD auto-resumes (if was playing) |
| SendSpin streaming + Enable AirPlay | AirPlay takes over, SendSpin stops |
| Manual restart SendSpin | MPD state saved, SendSpin restarts |

### Code Implementation (MPD Coexistence)

**When SendSpin starts:**
```php
function startSendspin() {
    // Save MPD state
    $mpdStatus = sysCmd('mpc status');
    $mpdWasPlaying = (!empty($mpdStatus) && strpos($mpdStatus[0], 'playing') !== false);
    phpSession('write', 'mpd_was_playing', $mpdWasPlaying ? '1' : '0');
    
    // Stop MPD
    sysCmd('mpc stop');
    
    // Start SendSpin
    sysCmd('systemctl start sendspin');
}
```

**When SendSpin stops:**
```php
function stopSendspin() {
    // Stop SendSpin
    sysCmd('systemctl stop sendspin');
    
    // Resume MPD if it was playing
    if ($_SESSION['mpd_was_playing'] == '1') {
        sleep(1); // Allow device release
        sysCmd('mpc play');
        phpSession('write', 'mpd_was_playing', '0');
    }
}
```

### Feature Bitmask Interaction

moOde uses a bitmask for feature flags. SendSpin is bit 18 (262144):

```php
// In constants.php
const FEAT_AIRPLAY    = 1;      // bit 0
const FEAT_MINIDLNA   = 2;      // bit 1
const FEAT_SPOTIFY    = 4096;   // bit 12
const FEAT_SENDSPIN   = 262144; // bit 18

// In cfg_system table
// feat_bitmask is OR of enabled features
// e.g., 262145 = FEAT_SENDSPIN | FEAT_AIRPLAY
```

**Other providers are unaffected** - each has its own bit and operates independently.

---

## Minimal vs Full Installation

### Minimal Install (Current)

```bash
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-integration/moode-sendspin-installer.sh | sudo bash -s -- --minimal
```

**Includes:**
- Basic UI controls (Enable/Disable, Name, Restart)
- Service management
- MPD coexistence
- ALSA configuration

**No metadata, no volume sync, no update check**

### Full Install (Future - Advanced Branch)

```bash
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-advanced/moode-sendspin-installer.sh | sudo bash
```

**Additional includes:**
- Now playing metadata display
- Volume sync with Music Assistant
- Version check and update button
- Server discovery
- Audio format/delay configuration

---

## Installation Modes Explained

### Mode 1: Basic (Default)
- Full UI integration
- All control features
- No metadata display

### Mode 2: Minimal (`--minimal`)
- Service management only
- No UI modifications
- For headless/custom UI setups

### Mode 3: Check (`--check`)
- Lists current installation status
- No changes made

### Mode 4: Uninstall (`--uninstall`)
- Removes all SendSpin components
- Restores original moOde files

---

## Interaction With Specific Providers

### AirPlay (shairport-sync)
- Both use ALSA output
- Enabling one stops the other
- moOde doesn't auto-switch between them
- User must manually toggle

### Spotify (librespot)
- Same behavior as AirPlay
- Independent on/off control
- No automatic handoff

### Deezer
- Same pattern as other renderers
- Exclusive audio access

### Bluetooth
- Uses different audio path (bluealsa)
- Can coexist with SendSpin
- No conflicts

### Squeezelite (Logitech Media Server)
- Uses direct ALSA access
- Conflicts with SendSpin if both enabled
- User must choose one

### Roon Bridge
- Multi-room like SendSpin
- Can theoretically coexist but not tested
- Likely conflicts on audio device

---

## Key Design Decisions

### 1. Why Manual Toggle Instead of Auto-Switch?

**Decision:** User must manually enable/disable SendSpin

**Rationale:**
- Prevents accidental interruptions
- Matches moOde's existing renderer pattern
- User controls when to switch audio sources
- Avoids confusion with automatic handoffs

### 2. Why Stop MPD Instead of Pause?

**Decision:** `mpc stop` instead of `mpc pause`

**Rationale:**
- Release ALSA device immediately
- Pause keeps device open (would block SendSpin)
- Stop allows clean handover
- Resume restores playback state

### 3. Why Direct Hardware Access?

**Decision:** `type plug` → `hw:0,0` instead of `_audioout`

**Rationale:**
- moOde's `_audioout` uses `dmix` which requires `ipc_key`
- Missing `ipc_key` causes intermittent failures
- Direct hardware is more reliable
- SendSpin manages its own audio buffer

---

## Files for GitHub Branches

### Branch: `sendspin-integration` (Release 1 - Minimal)

```
moode-sendspin-installer.sh     → Production ready
SENDSPIN_PR.md                  → Release 1 documentation
README-sendspin.md              → User documentation
```

### Branch: `sendspin-advanced` (Release 2 - Full)

```
moode-sendspin-installer.sh     → With metadata, volume sync, updates
SENDSPIN_ADVANCED_PR.md         → Release 2 documentation
hooks/sendspin-metadata-sink.py → Metadata sink daemon (HA polling mode)
sendspin-volume-sync.sh         → Volume synchronization
```

### Release 2: Metadata Sink (Implemented June 2026)

The metadata sink is a standalone daemon that writes now-playing track
information to moOde's metadata file format. It works around a Music
Assistant bug where MA advertises but does not populate the SendSpin
`metadata@v1` protocol role.

**How it works:**
- Daemon listens on port 8929 as a SendSpin client (metadata role)
- Polls Home Assistant REST API every 3 seconds for track data
- Writes to `/var/local/www/sendspinmeta.txt` in moOde format:
  `Title~~~Artist~~~Album~~~Duration~~~CoverPath~~~Codec`
- Downloads and caches cover art in `/var/local/www/imagesw/sendspin-covers/`
- SendSpin WebSocket connection kept for server monitoring only

**Requirements:**
- Home Assistant on local network (port 8123) accessible from Pi
- HA long-lived access token (stored in systemd service Environment)
- Music Assistant integrated with Home Assistant
- SendSpin CLI 7.5.0+ (provides aiosendspin library dependency)

**Service management:**
```bash
# Status
sudo systemctl status sendspin-metadata-sink

# Restart (use SIGKILL if stuck in deactivating)
sudo systemctl kill -s SIGKILL sendspin-metadata-sink
sleep 2
sudo systemctl reset-failed sendspin-metadata-sink
sudo systemctl start sendspin-metadata-sink

# View logs
sudo journalctl -u sendspin-metadata-sink -f
```

---

## Testing Checklist for Release 1

- [ ] Install minimal version
- [ ] Enable SendSpin in UI
- [ ] Verify service starts
- [ ] Stream from Music Assistant
- [ ] Disable SendSpin
- [ ] Verify MPD resumes (if was playing)
- [ ] Enable AirPlay while SendSpin active
- [ ] Verify SendSpin stops
- [ ] Uninstall SendSpin
- [ ] Verify clean removal

---

## Troubleshooting Minimal Install

### "Device in Use" Error
**Cause:** MPD or another renderer is holding ALSA device  
**Fix:** Enable SendSpin in UI first (stops MPD automatically)

### SendSpin Not Appearing in Music Assistant
**Cause:** Service not running or mDNS blocked  
**Fix:** Check `systemctl status sendspin`, verify port 44556/UDP

### MPD Not Resuming After Disable
**Cause:** MPD wasn't playing when SendSpin started  
**Fix:** Check `$_SESSION['mpd_was_playing']` in logs

---

*Documentation for SendSpin Release 1 (Minimal Install)*

---

## For moOde Maintainer

A comprehensive PR document for Tim Curtis is available at `SENDSPIN_PR.md`. It details every file changed, database schema, architecture decisions, code quality measures, and integration notes for incorporating SendSpin into the main moOde build.
