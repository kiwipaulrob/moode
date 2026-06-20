# SendSpin Integration for moOde - Pull Request

**Version:** 6.0.0  
**Date:** June 21, 2026  
**Author:** Paul Robertson (@kiwipaulrob)  

---

## Summary

This PR adds SendSpin multi-room audio renderer integration to moOde, allowing moOde to act as a synchronized audio endpoint in a SendSpin multi-room audio system (e.g., Music Assistant).

### Features
- Full UI integration in Configure → Renderers
- Service toggle with auto-save
- Custom endpoint naming
- Manual restart button
- Volume level matching (-3dB attenuation via ALSA)
- MPD coexistence (auto-stop/resume)
- Safe array access and error handling
- Direct hardware audio access (avoids dmix IPC issues)

---

## Files Changed

### 1. `/var/www/inc/constants.php`
- Added `FEAT_SENDSPIN = 262144` feature constant

### 2. `/var/www/inc/renderer.php`
- Added `getSendspinStatus()` - Safe service status checking
- Added `startSendspin()` - Service start with MPD state preservation
- Added `stopSendspin()` - Service stop with MPD resume
- Added `configureAlsaForSendspin()` - ALSA configuration logging

### 3. `/var/www/ren-config.php`
- Added POST handler for `update_sendspin_settings`
- Added POST handler for `sendspinrestart`
- Added session variable initialization
- Added `$autoClick` handler for JavaScript toggle

### 4. `/var/www/templates/ren-config.html`
- Added SendSpin configuration section
- Name input field with auto-save
- Service ON/OFF toggle
- Restart button with modal
- Help text for all fields

### 5. `/var/www/daemon/worker.php`
- Added startup check for SendSpin service
- Added `sendspinsvc` job handler
- Added `sendspinrestart` job handler

### 6. `/etc/systemd/system/sendspin.service`
- Systemd service definition with timeout
- Environment configuration
- Auto-restart on failure

### 7. `/etc/alsa/conf.d/sendspin.conf`
- ALSA plug plugin configuration
- Direct hardware access (card 0, device 0)

### 8. `/var/www/setup_3rdparty_sendspin.txt`
- Complete setup documentation
- Troubleshooting guide
- Command reference

---

## Installation

### Prerequisites
- moOde 9.x or later
- sendspin-cli installed (`uv tool install sendspin`)

### Quick Install
```bash
curl -fsSL https://raw.githubusercontent.com/kiwipaulrob/moode/sendspin-integration/moode-sendspin-installer.sh | sudo bash
```

### Manual Verification
```bash
# Check installation
sudo moode-sendspin-installer.sh --check

# View logs
sudo journalctl -u sendspin -f
```

---

## Code Quality Improvements (v6.0)

### Critical Fixes
1. **Safe Array Access** - `getSendspinStatus()` now checks array bounds before accessing `[0]`
2. **ALSA Stability** - Changed from `type route` to `type plug` with direct hardware to avoid dmix IPC key issues
3. **Service Timeout** - Added `TimeoutStartSec=30` for faster failure detection

### Minor Improvements
- Consistent quote usage in PHP
- Proper `$_select["sendspinname"]` session assignment
- Simplified `configureAlsaForSendspin()` logging
- Improved streaming detection using `fuser` + `pgrep`

---

## Testing Checklist

- [ ] Installer runs without errors
- [ ] PHP syntax valid for all modified files
- [ ] Database entries created correctly
- [ ] Service toggle works in UI
- [ ] Name field saves and persists
- [ ] Restart button functions
- [ ] MPD stops when SendSpin enabled
- [ ] MPD resumes when SendSpin disabled
- [ ] Audio plays from Music Assistant
- [ ] Volume levels match between sources
- [ ] No errors in `journalctl -u sendspin`

---

## Compatibility

| Component | Minimum Version | Notes |
|-----------|-----------------|-------|
| moOde | 9.0.0 | Tested on 9.4.2 |
| sendspin-cli | 7.5.0 | Hook support required for future metadata feature |
| PHP | 8.0 | Uses modern PHP syntax |

---

## Future Enhancement (Release 2)

### Now Playing Metadata Display

**Investigation Complete:** SendSpin provides metadata via environment variables through hook system.

**Required Changes:**
1. Add `--hook-start` and `--hook-stop` to service file
2. Create metadata capture script (`/var/local/www/commandw/sendspin-metadata.sh`)
3. Add `SENDSPINMETA_FILE` constant
4. Add metadata command to `renderer.php`
5. JavaScript polling for metadata updates
6. UI template updates for "Now Playing" display

**See detailed plan:** `SENDSPIN_RELEASE2_METADATA_PLAN.md`

---

## Troubleshooting

### "Device in Use" Error
MPD must release the ALSA device before SendSpin can use it. The integration handles this automatically - enable SendSpin in the UI first.

### SendSpin Not Appearing in Controller
1. Check service is active: `sudo systemctl status sendspin`
2. Verify mDNS: `sendspin --list-servers`
3. Check firewall: Port 44556/UDP for mDNS

### No Audio
1. Check ALSA config: `aplay -L | grep sendspin`
2. Verify device: `cat /etc/alsa/conf.d/sendspin.conf`
3. Test speaker: `speaker-test -D sendspin -c 2`

---

## Credits

- moOde audio player project by Tim Curtis
- SendSpin protocol by [author]
- Integration by Paul Robertson

---

## License

GPL-3.0-or-later (same as moOde)
