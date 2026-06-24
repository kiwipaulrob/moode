# SendSpin Integration — Code Review

**Branch:** sendspin-advanced  
**Date:** 2026-06-25  
**Reviewer:** Hermes Agent  
**Purpose:** Agent-assisted code review to identify bugs, structural issues, and improvements  
**Scope:** All SendSpin-specific files added or modified in this branch

---

## File Inventory

| File | Status | Description |
|------|--------|-------------|
| `www/ren-config.php` | Modified | Renderers config page — SendSpin section added |
| `www/ssp-config.php` | New | SendSpin settings page |
| `www/templates/ssp-config.html` | New | SendSpin settings template |
| `www/templates/ren-config.html` | Modified | Renderers template — SendSpin section added |
| `www/js/sendspin-display.js` | New | JS overlay for metadata display |
| `www/inc/renderer.php` | Modified | SendSpin renderer functions added |
| `hooks/sendspin-metadata-sink.py` | New | HA-polling metadata sink daemon |
| `hooks/spspre.sh` | Modified | Pre-start ALSA configuration |
| `hooks/sendspin-metadata.sh` | New | Hook for start/stop metadata write |
| `etc/systemd/system/sendspin.service` | New | SendSpin daemon service |
| `etc/systemd/system/moode-worker.service` | New | moOde worker daemon (replaces rc.local) |
| `etc/alsa/conf.d/sendspin.conf` | New | ALSA virtual device definition |

---

## Critical Bugs

### BUG-01: Indentation error in `startSendspin()` and `stopSendspin()` — `renderer.php` lines 429, 437

```php
// startSendspin() line 429:
tsysCmd('systemctl enable sendspin');

// stopSendspin() line 437:
tsysCmd('systemctl disable sendspin');
```

**Problem:** Both lines are prefixed with `t` instead of a tab character. PHP will interpret `tsysCmd(...)` as a call to an undefined function `tsysCmd`, causing a fatal error at runtime when these functions are called. This is most likely a copy-paste corruption or editor artifact.

**Fix:**
```php
sysCmd('systemctl enable sendspin');
// and
sysCmd('systemctl disable sendspin');
```

---

### BUG-02: `generateSendspinService()` calls `sqlConnect()` while caller already holds a connection — `renderer.php` line 511

```php
function generateSendspinService() {
    $dbh = sqlConnect();  // <-- opens second connection
    ...
}
```

**Problem:** This function is called from `ssp-config.php` which already holds `$dbh = sqlConnect()`. SQLite only supports one writer at a time; a second concurrent connection during the save handler can cause a lock error (`SQLITE_BUSY`). During testing this caused PHP-FPM to hang completely when `phpSession('load_system')` was also calling `sqlConnect()`.

**Fix:** Pass `$dbh` as a parameter instead of opening a new connection.

```php
function generateSendspinService($dbh = null) {
    if ($dbh === null) {
        $dbh = sqlConnect();
    }
    $result = sqlRead('cfg_sendspin', $dbh);
    ...
}
```

And in `ssp-config.php`:
```php
generateSendspinService($dbh);
```

---

### BUG-03: `ssp-config.php` save handler calls `submitJob('sendspinsvc', ...)` but does not restart the service — `ssp-config.php` lines 22–27

```php
generateSendspinService();
if ($_SESSION['sendspinsvc'] == '1') {
    $notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin settings applied (service restarted)');
} else {
    $notify = array('title' => '', 'msg' => '');
}
submitJob('sendspinsvc', '', $notify['title'], $notify['msg']);
```

**Problem:** `generateSendspinService()` writes the service file and calls `systemctl daemon-reload`, but **does not restart the service**. `submitJob('sendspinsvc', ...)` queues a job for the worker to toggle the service, but the worker's `sendspinsvc` job handler toggles it on/off based on the session variable — it may turn it off if it reads `sendspinsvc == 0`. The notification says "service restarted" but this may not happen.

**Fix:** After generating the service file, explicitly restart if running:
```php
generateSendspinService($dbh);
if ($_SESSION['sendspinsvc'] == '1') {
    sysCmd('sudo systemctl restart sendspin');
    $notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin settings applied and service restarted');
} else {
    $notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin settings saved (service not running)');
}
```

---

### BUG-04: `ssp-config.php` does not load `cfg_sendspin` values from DB after save — lines 43–59

```php
// Read config from DB
$result = sqlRead('cfg_sendspin', $dbh);
$cfgSendspin = array();
foreach ($result as $row) {
    $cfgSendspin[$row['param']] = $row['value'];
}
```

**Problem:** This read happens at the top of the file, **before** the POST save handler runs. When a user saves settings, the page is re-rendered with the **old** values (the new ones are in the DB but the read already happened). The user sees stale values until they manually refresh.

**Fix:** Move the DB read **after** the POST handler block:
```php
// Handle save
if (isset($_POST['save']) ...) {
    // ... save to DB ...
    generateSendspinService($dbh);
}

phpSession('close');

// Read AFTER save so form shows updated values
$result = sqlRead('cfg_sendspin', $dbh);
```

---

### BUG-05: `sendspin-display.js` pathname check is incomplete — line 14

```javascript
if (window.location.pathname !== '/' &&
    window.location.pathname !== '/index.php') {
    return;
}
```

**Problem:** This correctly prevents the overlay on config pages, but moOde uses hash-based navigation extensively (`/#configure-modal`, `/#queue-panel`, etc.). All of these land on `/` so the overlay activates even when the configure modal is open on the main page — potentially obscuring the modal. Additionally, if moOde ever serves `index.php` as a non-root path (e.g. under a subdirectory), the check will fail.

**Improvement:** Rather than checking which pages to allow, consider checking which pages to block:
```javascript
var configPages = ['/ren-config.php', '/ssp-config.php', '/apl-config.php',
    '/spo-config.php', '/sys-config.php'];
var isConfigPage = configPages.some(function(p) {
    return window.location.pathname === p;
});
if (isConfigPage) { return; }
```

Or more broadly — block any `.php` page that isn't `index.php`:
```javascript
var path = window.location.pathname;
if (path !== '/' && path !== '/index.php' && path.endsWith('.php')) {
    return;
}
```

---

## Significant Issues

### ISSUE-01: `ren-config.php` session fallback reads cfg_system into local `$_SESSION` but doesn't persist it — lines 226–235

```php
if (!isset($_SESSION['feat_bitmask'])) {
    $rows = sqlRead('cfg_system', $dbh);
    foreach ($rows as $row) {
        if (!str_contains($row['param'], 'RESERVED_')) {
            $_SESSION[$row['param']] = $row['value'];
        }
    }
    unset($_SESSION['wrkready']);
}
```

**Problem:** This correctly loads session data when a user has no cookie (incognito/first visit), but because the session was opened and closed before this block runs, `$_SESSION` is a local variable — the data is not written back to the session file. This means the page renders correctly this time, but **the next page request will again have an empty session**, causing the same blank rendering on every page the user visits. The user has no persistent session.

**Root cause:** The real fix should be to call `phpSession('load_system')` as the very first action (before any POST handling), ensuring the existing session is loaded using the stored session ID. This failed earlier due to a double `sqlConnect()` deadlock — which is actually BUG-02 causing BUG-ISSUE-01. Fix BUG-02 first, then this approach becomes safe.

**Recommended fix:**
```php
$dbh = sqlConnect();

// Always use the stored session ID so moOde's session is loaded
$storedId = sqlQuery("SELECT value FROM cfg_system WHERE param='sessionid'", $dbh);
if (!empty($storedId) && !empty($storedId[0]['value'])) {
    session_id($storedId[0]['value']);
}
phpSession('open');
```

This should replace the current `phpSession('open')` at line 14 and the entire fallback block at lines 226–235 can be removed.

---

### ISSUE-02: `startSendspin()` stops MPD unconditionally — `renderer.php` line 422

```php
// Stop MPD to release ALSA device
sysCmd('mpc stop');
```

**Problem:** This stops MPD whenever SendSpin starts — even if MPD wasn't playing. This is unnecessarily disruptive for users who have MPD idle. Other renderers (AirPlay, Spotify) do not do this; they rely on the ALSA device contention to naturally stop MPD only when audio is actually competing.

**Improvement:** Only stop MPD if it was actually playing:
```php
if ($mpdWasPlaying) {
    sysCmd('mpc stop');
}
```

---

### ISSUE-03: `generateSendspinService()` is not called at SendSpin install time — installer gap

**Problem:** When SendSpin is first installed via `moode-sendspin-installer.sh`, the service file is written with hardcoded defaults (`flac:48000:16:2`). If the user changes settings in `ssp-config.php`, `generateSendspinService()` regenerates the service file from the DB. But if the user has never visited the config page, the DB defaults may not match the installed service file (e.g. if the installer writes a different default).

**Improvement:** Call `generateSendspinService()` in the installer after creating the DB table, to ensure the service file and DB are always in sync from install.

---

### ISSUE-04: `getSendspinVersion()` calls `sendspin --version` but SendSpin is installed via `uv` — `renderer.php` line 482

```php
$result = sysCmd('sendspin --version 2>/dev/null');
```

**Problem:** `sendspin` may not be in `$PATH` for `www-data` processes. The binary lives at `/root/.local/share/uv/tools/sendspin/bin/sendspin`, which is only in root's PATH. This will return `unknown` for all web requests.

**Fix:** Use the absolute path:
```php
$result = sysCmd('/root/.local/share/uv/tools/sendspin/bin/sendspin --version 2>/dev/null');
```

Or define a constant at the top of renderer.php:
```php
const SENDSPIN_BIN = '/root/.local/share/uv/tools/sendspin/bin/sendspin';
```

---

### ISSUE-05: `updateSendspin()` uses `sleep(2)` blocking call — `renderer.php` line 503

```php
function updateSendspin() {
    sysCmd('uv tool upgrade sendspin 2>&1');
    sleep(2);
    sysCmd('systemctl restart sendspin 2>/dev/null');
```

**Problem:** `sysCmd('uv tool upgrade ...')` is synchronous and can take 30–60 seconds on a slow network. This blocks the PHP-FPM worker for the duration. Combined with `sleep(2)`, this can exhaust the FPM process pool and cause timeouts for other concurrent requests.

**Fix:** Run the upgrade asynchronously and handle the restart in the completion:
```php
function updateSendspin() {
    sysCmd('sudo -u root bash -c "uv tool upgrade sendspin && systemctl restart sendspin" > /tmp/sendspin-update.log 2>&1 &');
    workerLog('updateSendspin(): upgrade launched in background');
    return true;
}
```

---

### ISSUE-06: `ssp-config.php` does not have a SendSpin-specific DB fallback for missing session — structural inconsistency with `ren-config.php`

**Problem:** The session fallback fix was applied to `ren-config.php` but not to `ssp-config.php`. If a user navigates directly to `/ssp-config.php` in incognito, `$_SESSION['sendspinsvc']` will be empty, the "SendSpin will apply settings on next restart" branch may not trigger, and the page could render incorrectly.

**Fix:** Apply the same session fallback to `ssp-config.php`:
```php
phpSession('close');
if (!isset($_SESSION['feat_bitmask'])) {
    $rows = sqlRead('cfg_system', $dbh);
    foreach ($rows as $row) {
        if (!str_contains($row['param'], 'RESERVED_')) {
            $_SESSION[$row['param']] = $row['value'];
        }
    }
    unset($_SESSION['wrkready']);
}
```

---

## Structural Issues

### STRUCT-01: Mixed quoting style in `ren-config.php` SendSpin section — lines 392–403

```php
// Other renderers use single quotes consistently:
$_feat_bluetooth = $_SESSION['feat_bitmask'] & FEAT_BLUETOOTH ? '' : 'hide';

// SendSpin uses double quotes inconsistently:
if (($_SESSION["feat_bitmask"] & FEAT_SENDSPIN)) {
    $_feat_sendspin = "";
    $_SESSION["sendspin_installed"] == "yes" ...
```

**Fix:** Use single quotes throughout to match the rest of the file:
```php
if (($_SESSION['feat_bitmask'] & FEAT_SENDSPIN)) {
    $_feat_sendspin = '';
    $_SESSION['sendspin_installed'] == 'yes' ...
```

---

### STRUCT-02: `ssp-config.html` uses `<input type="number">` for delay — inconsistent with moOde UI patterns

```html
<input class="config-input-large" type="number" min="0" max="500" step="5"
    id="static-delay-ms" name="config[static_delay_ms]" ...>
```

**Problem:** Other moOde config pages use `<select>` dropdowns for constrained numeric values, not free-form number inputs. The number input lacks the styled orange "save" button that moOde uses for field saves, and doesn't use the `autoClick` pattern for immediate feedback.

**Improvement:** Either use a `<select>` with common delay values (0, 25, 50, 100, 150, 200, 300, 500ms) matching moOde's pattern, or add a styled save button.

---

### STRUCT-03: `ssp-config.php` does not call `waitWorker()` before rendering — structural gap

```php
// Missing: waitWorker('ssp-config');
$tpl = "ssp-config.html";
```

`waitWorker()` is called in all other config pages before template rendering. Its absence in `ssp-config.php` means the page renders while a worker job may still be processing, potentially showing stale values.

**Fix:** Add before template rendering:
```php
waitWorker('ssp_config');
```

(Note: already present in the code — verify the exact page key used matches worker.php's job names.)

---

### STRUCT-04: `sendspin-display.js` has no error handling for missing DOM elements

```javascript
var overlay = document.getElementById('sendspin-overlay');
if (overlay) {
    overlay.classList.remove('hide');
```

The overlay element check is guarded, but the title/artist/album/cover elements are not:
```javascript
var titleEl = document.getElementById('sendspin-title');
if (titleEl) titleEl.textContent = title;  // ✅ guarded
```

This is actually correctly guarded — no action needed.

---

### STRUCT-05: `sendspin-metadata-sink.py` imports `aiosendspin` but dependency is undocumented

```python
from aiosendspin.client.listener import ClientListener
from aiosendspin.client.client import ...
```

**Problem:** `aiosendspin` is a private/internal dependency bundled with the `sendspin` package. This is not documented in README or installer. If the user upgrades `sendspin` and `aiosendspin` API changes, the metadata sink will break silently.

**Improvement:** Add a version pin comment and startup version check:
```python
# Requires: sendspin >= 7.5.0 (aiosendspin bundled)
```

---

### STRUCT-06: `moode-worker.service` uses `Type=forking` but PIDFile path may not be cleaned up on crash

```ini
[Service]
Type=forking
PIDFile=/run/worker.pid
Restart=on-failure
```

**Problem:** If `worker.php` crashes after forking but before writing the PID, the PIDFile may not exist. On restart, systemd will log a warning. Additionally if the previous PIDFile is stale (leftover from a crash), `worker.php` will see the file locked and log `CRITICAL ERROR: Already running` on the first restart attempt.

**Fix:** Add `ExecStartPre` to clean the stale PIDFile:
```ini
ExecStartPre=/bin/rm -f /run/worker.pid
```

---

## Minor Issues

### MINOR-01: `spspre.sh` has no error handling

```bash
#!/bin/bash
sqlite3 /var/local/www/db/moode-sqlite3.db \
    "UPDATE cfg_system SET value='1' WHERE param='sendspinsvc'"
```

If `sqlite3` fails (DB locked, file missing), the script exits silently with error but systemd shows success. Add `set -e` and logging.

---

### MINOR-02: `sendspin-metadata-sink.py` has hardcoded HA entity ID

```python
ENTITY_ID = "media_player.moode_sendspin"
```

This should be read from a config file or environment variable so it works for users whose HA entity name differs.

---

### MINOR-03: `ren-config.html` SendSpin section uses inconsistent spacing vs other sections

The SendSpin section was added by appending to the template. A visual review shows minor indentation inconsistencies (5–6 tabs instead of 2 in a few closing divs, previously fixed but worth re-checking after the edit-button addition).

---

### MINOR-04: `generateSendspinService()` does not validate input values before writing service file

```php
$delay = $cfg['static_delay_ms'] ?? '0';
```

No validation that `$delay` is a non-negative integer, `$codec` is one of `flac|pcm`, or `$log_level` is a valid Python logging level. Malicious or corrupted DB values could produce an invalid service file.

**Fix:** Sanitise values before interpolation:
```php
$codec = in_array($cfg['audio_codec'] ?? '', ['flac', 'pcm']) ? $cfg['audio_codec'] : 'flac';
$rate = in_array($cfg['audio_rate'] ?? '', ['44100', '48000', '96000']) ? $cfg['audio_rate'] : '48000';
$depth = in_array($cfg['audio_depth'] ?? '', ['16', '24', '32']) ? $cfg['audio_depth'] : '16';
$delay = max(0, min(500, (int)($cfg['static_delay_ms'] ?? 0)));
$log_level = in_array($cfg['log_level'] ?? '', ['DEBUG', 'INFO', 'WARNING', 'ERROR']) ? $cfg['log_level'] : 'INFO';
```

---

## Summary Table

| ID | Severity | File | Issue |
|----|----------|------|-------|
| BUG-01 | **Critical** | `renderer.php` | `tsysCmd()` typo — undefined function, fatal error |
| BUG-02 | **Critical** | `renderer.php` | Double `sqlConnect()` in `generateSendspinService()` — SQLite lock |
| BUG-03 | **High** | `ssp-config.php` | Service not actually restarted on save |
| BUG-04 | **High** | `ssp-config.php` | DB read before POST save — stale form values after save |
| BUG-05 | **Medium** | `sendspin-display.js` | Pathname check allows overlay on configure modal |
| ISSUE-01 | **High** | `ren-config.php` | Session fallback doesn't persist — blank page on every config visit |
| ISSUE-02 | **Medium** | `renderer.php` | MPD stopped unconditionally on SendSpin start |
| ISSUE-03 | **Medium** | installer | `generateSendspinService()` not called at install time |
| ISSUE-04 | **Medium** | `renderer.php` | `sendspin` not in `www-data` PATH — version always `unknown` |
| ISSUE-05 | **Medium** | `renderer.php` | `updateSendspin()` blocks PHP-FPM for 30–60s |
| ISSUE-06 | **Medium** | `ssp-config.php` | Session fallback not applied to ssp-config.php |
| STRUCT-01 | Low | `ren-config.php` | Mixed quote style in SendSpin section |
| STRUCT-02 | Low | `ssp-config.html` | `<input type="number">` inconsistent with moOde UI pattern |
| STRUCT-03 | Low | `ssp-config.php` | `waitWorker()` — verify call is present and correct |
| STRUCT-05 | Low | `metadata-sink.py` | `aiosendspin` dependency undocumented |
| STRUCT-06 | Low | `moode-worker.service` | Stale PIDFile on crash causes restart failure |
| MINOR-01 | Info | `spspre.sh` | No error handling |
| MINOR-02 | Info | `metadata-sink.py` | Hardcoded HA entity ID |
| MINOR-03 | Info | `ren-config.html` | Minor indentation inconsistencies |
| MINOR-04 | Info | `renderer.php` | No input validation in `generateSendspinService()` |

---

## Recommended Fix Order

1. **BUG-01** — Fix `tsysCmd` typo (2 min, zero risk)
2. **BUG-02** — Pass `$dbh` to `generateSendspinService()` (10 min)
3. **BUG-04** — Move DB read after POST handler in `ssp-config.php` (5 min)
4. **ISSUE-01** — Replace session fallback with stored-session-ID approach (15 min, after BUG-02 fixed)
5. **BUG-03** — Explicit `systemctl restart` after service file generation (5 min)
6. **ISSUE-04** — Use absolute path for `sendspin` binary (2 min)
7. **MINOR-04** — Add input validation to `generateSendspinService()` (10 min)
8. **ISSUE-05** — Make `updateSendspin()` async (10 min)
9. **STRUCT-06** — Add `ExecStartPre=/bin/rm -f /run/worker.pid` (2 min)
10. **ISSUE-06** + **STRUCT-01/02** — Polish and consistency (20 min)

---

*Review generated by Hermes Agent — 2026-06-25*  
*All line numbers reference the `sendspin-advanced` branch at commit `ca2d4627`*
