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

		// Compare versions
		if ($_installed_version && version_compare($_installed_version, $_latest_version, '<')) {
			$_update_available = true;
		}
	}
} else {
	$_latest_version_display = 'Unable to check';
}

$_select['sendspin_update_btn'] = $_SESSION['sendspinsvc'] == '1' && $_update_available ?
	'<button class="btn btn-medium btn-primary config-btn" type="submit" name="update_sendspin" value="1">Update</button>' :
	'';

$_select['installed_version'] = $_installed_version_display;
$_select['latest_version'] = $_latest_version_display;
$_select['update_available'] = $_update_available ? 'yes' : 'no';

waitWorker('ssp_config');

$tpl = "ssp-config.html";
$section = basename(__FILE__, '.php');
storeBackLink($section, $tpl);

include('header.php');
eval("echoTemplate(\"" . getTemplate("templates/$tpl") . "\");");
include('footer.min.php');
