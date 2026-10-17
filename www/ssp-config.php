<?php
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2024 SendSpin moOde integration
 */

require_once __DIR__ . '/inc/common.php';
require_once __DIR__ . '/inc/session.php';
require_once __DIR__ . '/inc/renderer.php';
require_once __DIR__ . '/inc/sql.php';

$dbh = sqlConnect();
phpSession('open');

// Handle save
if (isset($_POST['save']) && $_POST['save'] == '1' && isset($_POST['config']) && is_array($_POST['config'])) {
	// Upstream pattern: allowlist POST keys against the table's own params
	$validKeys = array();
	foreach (sqlRead('cfg_sendspin', $dbh) as $row) { $validKeys[] = $row['param']; }
	foreach ($_POST['config'] as $key => $value) {
		chkKey($key, $validKeys);
		chkValue($key, $value);
		sqlUpdate('cfg_sendspin', $dbh, $key, $value);
	}
	// Regenerate service file from updated config
	generateSendspinService($dbh);
	
	// Restart service if running
	if (($_SESSION['sendspinsvc'] ?? '0') == '1') {
		sysCmd('sudo systemctl restart sendspin >/dev/null 2>&1 &');
		$notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin settings applied and service restarted');
	} else {
		$notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin settings saved (service not running)');
	}
	submitJob('sendspinsvc', '', $notify['title'], $notify['msg']);
}

// Handle update request
if (isset($_POST['update_sendspin']) && $_POST['update_sendspin'] == '1') {
	if (($_SESSION['sendspinsvc'] ?? '0') == '1') {
		updateSendspin();
		$notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin update launched in background (patches within the pinned version)');
	} else {
		$notify = array('title' => '', 'msg' => '');
	}
	submitJob('sendspinsvc', '', $notify['title'], $notify['msg']);
}

phpSession('close');

// If session is empty (no cookie or incognito), load all cfg_system into session
if (!isset($_SESSION['feat_bitmask'])) {
	$rows = sqlRead('cfg_system', $dbh);
	foreach ($rows as $row) {
		if (!str_contains($row['param'], 'RESERVED_')) {
			$_SESSION[$row['param']] = $row['value'];
		}
	}
	unset($_SESSION['wrkready']);
}

// Read config from DB
$result = sqlRead('cfg_sendspin', $dbh);
$cfgSendspin = array();
foreach ($result as $row) {
	$cfgSendspin[$row['param']] = $row['value'];
}

// Get installed version (cached — getSendspinVersion() takes ~2s)
$versionCacheFile = '/tmp/sendspin_local_version.txt';
$versionCacheAge = 86400; // 24 hours
if (file_exists($versionCacheFile) && (time() - filemtime($versionCacheFile)) < $versionCacheAge) {
	$_installed_version = trim(@file_get_contents($versionCacheFile));
} else {
	$_installed_version = getSendspinVersion();
	if ($_installed_version) {
		@file_put_contents($versionCacheFile, $_installed_version);
	}
}
$_installed_version_display = htmlspecialchars($_installed_version ?: 'Not installed');

// Check for latest version via PyPI JSON API (cached hourly)
$_latest_version_display = '';
$_update_available = false;
$_can_update = false;

// Pinned channel: the installer pins a sendspin>=X.Y,<X.Z line in the uv
// receipt, so the Update button (bare `uv tool upgrade`) delivers patches on
// that line but can never jump majors. New majors ship with an installer
// re-run (new pin range). $mm() reduces a version to its major.minor line.
$mm = function ($v) {
	$p = explode('.', preg_replace('/[^0-9.]/', '', (string)$v));
	return ($p[0] ?? '0') . '.' . ($p[1] ?? '0');
};
$_pin_spec = '';
$_pinned_version = '';
$_pinned_version_display = 'Not pinned';
$_major_available = false;
$receipt = @file_get_contents('/root/.local/share/uv/tools/sendspin/uv-receipt.toml');
if ($receipt !== false && preg_match('/specifier\s*=\s*"([^"]+)"/', $receipt, $m)) {
	$_pin_spec = $m[1];
	if (preg_match('/>=\s*([0-9][0-9.]*)/', $_pin_spec, $v)) {
		$_pinned_version = $v[1];
	} elseif (preg_match('/==\s*([0-9][0-9.]*)/', $_pin_spec, $v)) {
		$_pinned_version = $v[1];
	}
	$_pinned_version_display = htmlspecialchars($_pin_spec);
}


$cacheFile = '/tmp/sendspin_version_cache.json';
$cacheAge = 3600; // 1 hour

if (file_exists($cacheFile) && (time() - filemtime($cacheFile)) < $cacheAge) {
	$pypi_json = @file_get_contents($cacheFile);
} else {
	$pypi_url = 'https://pypi.org/pypi/sendspin/json';
	$pypi_json = @file_get_contents($pypi_url, false, stream_context_create(array(
		'http' => array(
			'timeout' => 3,
			'method' => 'GET',
			'header' => "Accept: application/json\r\n"
		)
	)));
	if ($pypi_json !== false) {
		@file_put_contents($cacheFile, $pypi_json);
	}
}

if ($pypi_json !== false) {
	$pypi_data = json_decode($pypi_json, true);
	if (isset($pypi_data['info']['version'])) {
		$_latest_version = $pypi_data['info']['version'];
		$_latest_version_display = htmlspecialchars($_latest_version);
		$_can_update = true;
		if ($_installed_version && version_compare($_installed_version, $_latest_version, '<')) {
		if ($_pinned_version && version_compare($mm($_latest_version), $mm($_pinned_version), '>')) {
			// A newer line exists upstream (beyond the pinned major.minor).
			$_major_available = true;
		} elseif ($_pinned_version && version_compare($mm($_installed_version), $mm($_pinned_version), '<')) {
			// Installed is behind the pinned line entirely: the installer
			// re-run owns this state, not the button.
			$_major_available = true;
		} else {
			$_update_available = true;
		}


	}
	}
} else {
	$_latest_version_display = 'Unable to check';
}

// Build selects
$_select['sendspin_update_btn'] = (($_SESSION['sendspinsvc'] ?? '0') == '1') && $_update_available ?
	'<button class="btn btn-medium btn-primary config-btn" type="submit" name="update_sendspin" value="1">Update</button>' :
	'';

$_select['installed_version'] = $_installed_version_display;
$_select['latest_version'] = $_latest_version_display;
$_select['pinned_version'] = $_pinned_version_display;
$_select['update_available'] = $_update_available ? 'yes' : 'no';
$_major_note = '';
if (!empty($_major_available)) {
	$_major_note = 'A newer SendSpin line (' . htmlspecialchars($_latest_version) . ') is available upstream — it ships with an installer re-run, not this button.';
} elseif ($_pinned_version && $_installed_version && version_compare($mm($_installed_version), $mm($_pinned_version), '>')) {
	$_major_note = 'Installed ' . htmlspecialchars($_installed_version) . ' is ahead of the pinned line (' . htmlspecialchars($_pin_spec) . ') — the next installer re-run will set it back.';
}

$_select['major_note'] = $_major_note ? '<span class="config-btn-after">Note: ' . $_major_note . '</span>' : '';

// Audio codec
$codec = $cfgSendspin['audio_codec'] ?? 'flac';
$_select['audio_codec'] .= "<option value=\"flac\" " . (($codec == 'flac') ? "selected" : "") . ">FLAC</option>\n";
$_select['audio_codec'] .= "<option value=\"pcm\" " . (($codec == 'pcm') ? "selected" : "") . ">PCM</option>\n";

// Sample rate
$rate = $cfgSendspin['audio_rate'] ?? '48000';
$_select['audio_rate'] .= "<option value=\"44100\" " . (($rate == '44100') ? "selected" : "") . ">44100 Hz</option>\n";
$_select['audio_rate'] .= "<option value=\"48000\" " . (($rate == '48000') ? "selected" : "") . ">48000 Hz (Default)</option>\n";
$_select['audio_rate'] .= "<option value=\"96000\" " . (($rate == '96000') ? "selected" : "") . ">96000 Hz</option>\n";

// Bit depth
$depth = $cfgSendspin['audio_depth'] ?? '16';
$_select['audio_depth'] .= "<option value=\"16\" " . (($depth == '16') ? "selected" : "") . ">16 bit (Default)</option>\n";
$_select['audio_depth'] .= "<option value=\"24\" " . (($depth == '24') ? "selected" : "") . ">24 bit</option>\n";
$_select['audio_depth'] .= "<option value=\"32\" " . (($depth == '32') ? "selected" : "") . ">32 bit</option>\n";

// Log level
$log_level = $cfgSendspin['log_level'] ?? 'INFO';
$_select['log_level'] .= "<option value=\"DEBUG\" " . (($log_level == 'DEBUG') ? "selected" : "") . ">DEBUG</option>\n";
$_select['log_level'] .= "<option value=\"INFO\" " . (($log_level == 'INFO') ? "selected" : "") . ">INFO (Default)</option>\n";
$_select['log_level'] .= "<option value=\"WARNING\" " . (($log_level == 'WARNING') ? "selected" : "") . ">WARNING</option>\n";
$_select['log_level'] .= "<option value=\"ERROR\" " . (($log_level == 'ERROR') ? "selected" : "") . ">ERROR</option>\n";



// ALSA card info
$cardResult = sysCmd("sqlite3 /var/local/www/db/moode-sqlite3.db \"SELECT value FROM cfg_system WHERE param='cardnum'\" 2>/dev/null");
$_select['alsa_cardnum'] = (!empty($cardResult) && isset($cardResult[0])) ? trim($cardResult[0]) : '?';
$nameResult = sysCmd("sqlite3 /var/local/www/db/moode-sqlite3.db \"SELECT value FROM cfg_system WHERE param='devname'\" 2>/dev/null");
$_select['alsa_devname'] = (!empty($nameResult) && isset($nameResult[0])) ? trim($nameResult[0]) : 'unknown';

waitWorker('ssp_config');

$tpl = "ssp-config.html";
$section = basename(__FILE__, '.php');
storeBackLink($section, $tpl);

include('header.php');
eval("echoTemplate(\"" . getTemplate("templates/$tpl") . "\");");
include('footer.min.php');
