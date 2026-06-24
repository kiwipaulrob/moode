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
if (isset($_POST['save']) && $_POST['save'] == '1') {
	foreach ($_POST['config'] as $key => $value) {
		chkValue($key, $value);
		sqlUpdate('cfg_sendspin', $dbh, $key, $value);
	}
	// Regenerate service file from updated config
	generateSendspinService($dbh);
	// Restart service if running
	if ($_SESSION['sendspinsvc'] == '1') {
		sysCmd('sudo systemctl restart sendspin');
		$notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin settings applied and service restarted');
	} else {
		$notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin settings saved (service not running)');
	}
	submitJob('sendspinsvc', '', $notify['title'], $notify['msg']);
}

// Handle update request
if (isset($_POST['update_sendspin']) && $_POST['update_sendspin'] == '1') {
	if ($_SESSION['sendspinsvc'] == '1') {
		updateSendspin();
		$notify = array('title' => NOTIFY_TITLE_INFO, 'msg' => 'SendSpin updated and restarted');
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

// Get installed version
$_installed_version = getSendspinVersion();
$_installed_version_display = htmlspecialchars($_installed_version ?: 'Not installed');

// Check for latest version via PyPI JSON API
$_latest_version_display = '';
$_update_available = false;
$_can_update = false;

$pypi_url = 'https://pypi.org/pypi/sendspin/json';
$pypi_json = @file_get_contents($pypi_url, false, stream_context_create(array(
	'http' => array(
		'timeout' => 5,
		'method' => 'GET',
		'header' => "Accept: application/json\r\n"
	)
)));

if ($pypi_json !== false) {
	$pypi_data = json_decode($pypi_json, true);
	if (isset($pypi_data['info']['version'])) {
		$_latest_version = $pypi_data['info']['version'];
		$_latest_version_display = htmlspecialchars($_latest_version);
		$_can_update = true;
		if ($_installed_version && version_compare($_installed_version, $_latest_version, '<')) {
			$_update_available = true;
		}
	}
} else {
	$_latest_version_display = 'Unable to check';
}

// Build selects
$_select['sendspin_update_btn'] = $_SESSION['sendspinsvc'] == '1' && $_update_available ?
	'<button class="btn btn-medium btn-primary config-btn" type="submit" name="update_sendspin" value="1">Update</button>' :
	'';

$_select['installed_version'] = $_installed_version_display;
$_select['latest_version'] = $_latest_version_display;
$_select['update_available'] = $_update_available ? 'yes' : 'no';

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

// Static delay
$_select['static_delay_ms'] = $cfgSendspin['static_delay_ms'] ?? '0';

// Log level
$log_level = $cfgSendspin['log_level'] ?? 'INFO';
$_select['log_level'] .= "<option value=\"DEBUG\" " . (($log_level == 'DEBUG') ? "selected" : "") . ">DEBUG</option>\n";
$_select['log_level'] .= "<option value=\"INFO\" " . (($log_level == 'INFO') ? "selected" : "") . ">INFO (Default)</option>\n";
$_select['log_level'] .= "<option value=\"WARNING\" " . (($log_level == 'WARNING') ? "selected" : "") . ">WARNING</option>\n";
$_select['log_level'] .= "<option value=\"ERROR\" " . (($log_level == 'ERROR') ? "selected" : "") . ">ERROR</option>\n";

waitWorker('ssp_config');

$tpl = "ssp-config.html";
$section = basename(__FILE__, '.php');
storeBackLink($section, $tpl);

include('header.php');
eval("echoTemplate(\"" . getTemplate("templates/$tpl") . "\");");
include('footer.min.php');
