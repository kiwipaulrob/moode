# SendSpin for moOde — Feature Status

**Branch:** `sendspin-advanced`
**Updated:** 2026-07-25
**Installer:** v4.1.0
**Merged:** moOde r1031 (upstream/develop)

### Latest (2026-07-25) — Metadata Display + r1031 Compatibility

- **Metadata display** — `sendspin-meta.php` endpoint, `sendspin-display.js` poller, `<script>` tag auto-added to `header.php`
- **Installer now 17 components** — added 3: metadata endpoint, display JS, header include
- **Merged with upstream moOde r1031** — 23 commits behind → 0
- **JS file detection** — supports `playerlib.js` (r1031+) and `lib.min.js` (older moOde)
- **`feat_bitmask` dedup fix** — changed `INSERT OR REPLACE` to `UPDATE` to prevent duplicate rows
- **`FEAT_SENDSPIN` re-added to constants.php** — restored after merge overwrite

## v4.1.0 — Critical Fixes & Service Hardening (2026-06-28)

### Bug Fixes
- **Deployed missing commandw lifecycle scripts** — `sendspin-spspre.sh`, `sendspin-metadata.sh`, `spspost.sh`, `sendspin-version-check.sh` now included in installer
- **Fixed HTML nesting in ren-config.html** — SendSpin section is now a proper sibling of RoonBridge (was incorrectly nested inside)
- **Fixed installer BRANCH reference** — Changed from `sendspin-integration` to `sendspin-advanced` to match git branch
- **Removed unnecessary `install_moode_worker_service()`** — `moode-worker.service` is a core moOde component that ships with every 9.x install; overwriting it risked PHP-FPM version mismatch
- **Removed dead `queue.php` references** — SendSpin jobs are dispatched by `worker.php`; `queue.php` is the generic job submission endpoint requiring no per-renderer modifications

### Improvements
- **Added Resume MPD toggle** (`rsmafterss`) — User-controlled MPD auto-resume after SendSpin stops, with ON/OFF toggle in ren-config UI
- **Consolidated service file generation** — `ren-config.php` now calls `generateSendspinService()` instead of brittle `sed` patching
- **Persisted MPD resume state in database** — `sendspin_mpd_was_playing` stored in `cfg_system` table (survives PHP-FPM restarts)
- **Dual fallback for MPD resume** — Checks both `$_SESSION` and database for `mpd_was_playing` state
- **Uninstall cleanup** covers commandw scripts and directory removal
- **Bash syntax validation** passes clean

### Installer Summary: v4.1.0
- Detects **14 components** (was 11, then 15 before removing redundancy)
- `install_commandw_scripts()` deploys 4 lifecycle scripts from GitHub
- Verification covers all legitimately needed files
- Uninstall (both backup-restore and manual cleanup paths) removes commandw artifacts

## Completed Features (v4.0.0)

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

### 4. Service Lifecycle (v4.0.0 — superseded in v4.1.0)
- `sendspin-spspre.sh` — pre-start hook (v4.1.0: now validates `_audioout`, no longer writes ALSA config)
- `sendspin.service` — systemd unit with Restart=on-failure, real-time priority
- Service file regeneration from DB (survives reboot)
- **Hook scripts added in v4.1.0** — `--hook-start`/`--hook-stop` write metadata directly
- `spspost.sh` — post-stop cleanup hook

### 5. Session Handling
- Stored session ID restored before `phpSession('open')` — works in incognito/no-cookie
- All session variables have defaults
- `Resume MPD` toggle (`rsmafterss`) — user-controlled MPD auto-resume

### 6. Dynamic ALSA Device Support (v4.0.0 — superseded in v4.1.0)
- ALSA card number was read from DB (v4.1.0: switched to moOde's static `_audioout` device)
- No separate ALSA config needed — uses same device as AirPlay/Spotify/MPD

## Deferred / Not Implemented

### CamillaDSP Loopback Support (was Priority 3)
- **Status:** Deferred indefinitely
- **Reason:** CamillaDSP operates downstream of the ALSA plug layer. SendSpin audio flows through `sendspin → plughw → DAC`, and CamillaDSP processes audio after that point. It works transparently without any SendSpin-specific code. The only exception is Bluetooth, which has a CDSP maxvol setting due to Bluetooth's unique volume path — SendSpin does not share this issue.

### Buffer Tuning for Sync Precision (was Priority 4)
- **Status:** Removed (v4.1.0)
- **Reason:** Music Assistant handles network-layer synchronisation. `--static-delay-ms` would duplicate this. The flag and `static_delay_ms` DB field were removed entirely.

### Installer Quality
- **Status:** Complete
- **Installer v4.1.0** — 14-component detection, backup + uninstall, sed operations guarded with `|| true`, dynamic PHP-FPM version detection, `require_once` patching for `renderer.php` dependency
- **Reuses existing `$dbh`** connection in `ren-config.php` POST handler (no unnecessary reconnect)
- **Uses moOde's `_audioout` device** — same ALSA path as AirPlay, Spotify, MPD; volume knob works natively, no attenuation hacks needed
- **Follows renderer patterns** — `vol.sh -restore`, CDSP volume sync, `sspactive` flag, `sendFECmd('sspactive0')` on stop, matching all other renderers
- **Removed `configureAlsaForSendspin()`**, `install_alsa_config()`, `sendspin.conf` ALSA device — dead code and unused architecture

### Volume Sync with Music Assistant
- **Status:** Not started
- **Reason:** moOde's integrated volume management handles audio levels. Passing a separate `--hardware-volume` flag would duplicate or conflict. Volume is delegated to moOde's system-level control.
- **Removed from backend (v4.1.0):** `--hardware-volume` flag, `volume_mode` from `cfg_sendspin` table, `$_select['volume_mode']` from `ssp-config.php`

## Future Considerations

- **Upgrade path for moOde 10:** The installer handles re-patching after a moOde update. Documentation covers this.
- **PR to upstream moOde:** `SENDSPIN_PR.md` documents all changes for maintainer review.
