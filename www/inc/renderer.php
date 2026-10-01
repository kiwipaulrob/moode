<?php
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2014 The moOde audio player project / Tim Curtis
*/

require_once __DIR__ . '/common.php';
require_once __DIR__ . '/cdsp.php';
require_once __DIR__ . '/multiroom.php';
require_once __DIR__ . '/session.php';
require_once __DIR__ . '/sql.php';

// Bluetooth
// Write the pairing agent's capability file. On ('1') -> DisplayYesNo (the agent asks
// the user to confirm the pairing code); off -> NoInputNoOutput (Just Works). Read by
// bt-agent.service via EnvironmentFile; the caller restarts bt-agent to apply it.
function applyBtPairingConfirm($confirm) {
	$capability = $confirm == '1' ? 'DisplayYesNo' : 'NoInputNoOutput';
	file_put_contents(BT_AGENT_ENV, 'BT_AGENT_CAPABILITY=' . $capability . "\n");
}
function startBluetooth() {
	sysCmd('systemctl start hciuart');
	sysCmd('systemctl start bluetooth');

	// Check for first run (no MAC addr yet) fail
	$result = sysCmd('systemctl status bluetooth | grep -i failed');
	//DEBUG:workerLog(print_r($result, true));
	if (!empty($result)) {
		// Stop/start
		stopBluetooth();
		sysCmd('systemctl start bluetooth');
	}

	// Check for successful daemon startup
	$result = sysCmd('pgrep bluetoothd');
	if (empty($result)) {
		$status = 'ERROR: Bluetooth startup failed';
	} else {
		// Check for controller MAC address
		$result = sysCmd('ls /var/lib/bluetooth');
		if (empty($result)) {
			$status = 'ERROR: Bluetooth MAC address not found';
		} else {
			// All good
			sysCmd('systemctl start bt-agent');
			sysCmd('systemctl start bluealsa');
			sysCmd('/var/www/util/blu-control.sh -i');
			$status = 'started';
		}
	}

	return $status;
}
function stopBluetooth() {
	sysCmd('systemctl stop bt-agent');
	sysCmd('systemctl stop bluealsa');
	sysCmd('systemctl stop bluetooth');
	sysCmd('killall -s 9 bluealsa-aplay');
}

// AirPlay
function startAirPlay() {
	if ($_SESSION['airplaysvc_type'] == '2') {
		sysCmd('systemctl start nqptp');
	}

	// Verbose logging
	if ($_SESSION['debuglog'] == '1') {
		$logging = '-v';
		$logFile = SHAIRPORT_SYNC_LOG;
	} else {
		$logging = '';
		$logFile = '/dev/null';
	}

	// Output device
	// TODO: Still necessary with AirPlay 5
	// NOTE: Specifying Loopback instead of _audioout when Multiroom TX is On greatly reduces audio glitches
	$device = $_SESSION['audioout'] == 'Local' ? ($_SESSION['multiroom_tx'] == 'On' ? 'plughw:Loopback,0' : '_audioout') : 'btstream';

	// NOTE: All other params are in /etc/shairport-sync.conf
	$cmd = '/usr/bin/shairport-sync ' . $logging .
		' -a "' . $_SESSION['airplayname'] . '" ' .
		'-- -d ' . $device . ' > ' . $logFile . ' 2>&1 &';

	// Start AirPlay receiver
	debugLog('startAirPlay(): (' . $cmd . ')');
	sysCmd($cmd);

	// Wait until metadata pipe is ready
	$maxRetries = 3;
	for ($i = 0; $i < $maxRetries; $i++) {
		$result = sysCmd('ls -1 /tmp/shairport-sync-metadata | wc -l')[0];
		//debugLog('result=' . $result);

		if ($result != 0) {
			break;
		}
		debugLog('startAirPlay(): Retry ' . ($i + 1) . ' waiting for metadata pipe');
		sleep(1);
	}

	// Start AirPlay metadata reader
	$cmd = '/var/www/daemon/aplmeta-reader.sh > /dev/null 2>&1 &';
	debugLog('startAirPlay(): (' . $cmd . ')');
	sysCmd($cmd);

	// Truncate metadata file
	sysCmd('truncate ' . APLMETA_CACHE_FILE . ' --size 0');
}
function stopAirPlay() {
	$maxRetries = 3;
	// Stop metadata reader components
	for ($i = 0; $i < $maxRetries; $i++) {
		sysCmd('pkill -f -9  aplmeta-reader.sh');
		sysCmd('pkill -f -9  shairport-sync-metadata-reader');
		sysCmd('pkill -f -9  aplmeta.py');
		sysCmd('pkill -f -9  cat');
		// Use the 15 char names from PS -A for some of these
		$result1 = sysCmd('pgrep -cx "aplmeta-reader."')[0]; // aplmeta.sh
		$result2 = sysCmd('pgrep -cx "shairport-sync-"')[0]; // shairport-sync-metadata-reader
		$result3 = sysCmd('pgrep -cx "aplmeta.py"')[0];
		$result4 = sysCmd('pgrep -cfax "cat /tmp/shairport-sync-metadata"')[0];

		// DEBUG
		/*workerLog('result1=' . $result1);
		workerLog('result2=' . $result2);
		workerLog('result3=' . $result3);
		workerLog('result4=' . $result4);
		}*/

		if ($result1 == 0 && $result2 == 0 && $result3 == 0 && $result4 == 0) {
			break;
		}
		workerLog('worker: Retry ' . ($i + 1) . ' stopping AirPlay metadata reader components');
		sleep(1);
	}
	// Stop shairport-sync
	for ($i = 0; $i < $maxRetries; $i++) {
		$result = sysCmd('pkill -c -f -9 "[s]hairport-sync"');
		//workerLog(print_r($result, true));

		$result = sysCmd('pgrep -c -f "[L]C_ALL=C /usr/bin/shairport-sync"')[0];
		//workerLog(print_r($result, true));
		if ($result == 0) {
			break;
		}
		workerLog('worker: Retry ' . ($i + 1) . ' stopping AirPlay (shairport-sync)');
		sleep(1);
	}
	// Stop nqptp
	sysCmd('systemctl stop nqptp');

	// Local
	sysCmd('/var/www/util/vol.sh -restore');
	if (CamillaDSP::isMPD2CamillaDSPVolSyncEnabled()) {
		sysCmd('systemctl restart mpd2cdspvolume');
	}
	// Multiroom receivers
	if ($_SESSION['multiroom_tx'] == "On" ) {
		updReceiverVol('-restore');
	}

	phpSession('write', 'aplactive', '0');
	$GLOBALS['aplactive'] = '0';
	sendFECmd('aplactive0');
}
function getAirPlayVersion($type = 'full') {
	$version = sysCmd('shairport-sync -V | cut -f 1 -d "-"')[0];
	// $type: 'full' or 'major'
	return ($type == 'full' ? $version : substr($version, 0, 1));
}
function isAirPlayInstalled() {
	$installedVersion = sysCmd('dpkg-query --showformat=\'${Version}\n\' --show shairport-sync | grep moode')[0];
	return (empty($installedVersion) ? false : true);
}
function isAirPlayUpgradable() {
	// Ex: 5.0.2-1moode1
	$installedVersion = sysCmd('dpkg-query --showformat=\'${Version}\n\' --show shairport-sync | grep moode')[0];
	$availableVersion = sqlQuery("SELECT version FROM cfg_plugin WHERE component='renderer' AND type='airplay'", sqlConnect())[0]['version'];
	return ($installedVersion == $availableVersion ? false : true);
}

// Spotify Connect
function startSpotify() {
	$result = sqlRead('cfg_spotify', sqlConnect());
	$cfgSpotify = array();
	foreach ($result as $row) {
		$cfgSpotify[$row['param']] = $row['value'];
	}

	// Output device
	$device = $_SESSION['audioout'] == 'Local' ? '_audioout' : 'btstream';

	// Options
	$dither = empty($cfgSpotify['dither']) ? '' : ' --dither ' . $cfgSpotify['dither'];
	$normalization = $cfgSpotify['volume_normalization'] == 'Yes' ?
		' --enable-volume-normalisation ' .
		' --normalisation-method ' . $cfgSpotify['normalization_method'] .
		' --normalisation-gain-type ' . $cfgSpotify['normalization_gain_type'] .
		' --normalisation-pregain ' .  $cfgSpotify['normalization_pregain'] .
		' --normalisation-threshold ' . $cfgSpotify['normalization_threshold'] .
		' --normalisation-attack ' . $cfgSpotify['normalization_attack'] .
		' --normalisation-release ' . $cfgSpotify['normalization_release'] .
		' --normalisation-knee ' . $cfgSpotify['normalization_knee']
		: '';

	$autoplay = $cfgSpotify['autoplay'] == 'Yes' ? ' --autoplay on' : '';
	$zeroconf = $cfgSpotify['zeroconf'] == 'manual' ? ' --zeroconf-port ' . $cfgSpotify['zeroconf_port'] : '';

	// Logging
	$logging = $_SESSION['debuglog'] == '1' ? ' -v > ' . LIBRESPOT_LOG : ' > /dev/null';

 	// NOTE: We use --disable-audio-cache because the audio file cache eats disk space.
	$cmd = 'librespot' .
		' --name "' . $_SESSION['spotifyname'] . '"' .
		' --bitrate ' . $cfgSpotify['bitrate'] .
		' --format ' . $cfgSpotify['format'] .
		$dither .
		' --mixer softvol' .
		' --initial-volume ' . $cfgSpotify['initial_volume'] .
		' --volume-ctrl ' . $cfgSpotify['volume_curve'] .
		' --volume-range ' . $cfgSpotify['volume_range'] .
		$normalization .
		$autoplay .
		$zeroconf .
		' --cache /var/local/www/spotify_cache --disable-audio-cache --backend alsa --device "' . $device . '"' .
		' --onevent /var/local/www/commandw/spotevent.sh' .
		$logging . ' 2>&1 &';

	debugLog('startSpotify(): (' . $cmd . ')');
	sysCmd($cmd);

	// Truncate metadata file
	sysCmd('truncate ' . SPOTMETA_CACHE_FILE . ' --size 0');
}
function stopSpotify() {
	sysCmd('killall -s9 librespot');

	// Local
	sysCmd('/var/www/util/vol.sh -restore');
	if (CamillaDSP::isMPD2CamillaDSPVolSyncEnabled()) {
		sysCmd('systemctl restart mpd2cdspvolume');
	}
	// Multiroom receivers
	if ($_SESSION['multiroom_tx'] == "On" ) {
		updReceiverVol('-restore');
	}

	phpSession('write', 'spotactive', '0');
	$GLOBALS['spotactive'] = '0';
	sendFECmd('spotactive0');
}
function isSpotifyInstalled() {
	$installedVersion = sysCmd('dpkg-query --showformat=\'${Version}\n\' --show librespot | grep moode')[0];
	return (empty($installedVersion) ? false : true);
}
function isSpotifyUpgradable() {
	// Ex: 0.8.0-1moode1
	$installedVersion = sysCmd('dpkg-query --showformat=\'${Version}\n\' --show librespot | grep moode')[0];
	$availableVersion = sqlQuery("SELECT version FROM cfg_plugin WHERE component='renderer' AND type='spotify-connect'", sqlConnect())[0]['version'];
	return ($installedVersion == $availableVersion ? false : true);
}

// Qobuz Connect
// Copyright 2026 @PhilipVinc qbz fork of moode / https://github.com/PhilipVinc/moode
function cfgQobuz() {
	// Settings
	$result = sqlRead('cfg_qobuz', sqlConnect());
	$cfgQobuz = array();
	foreach ($result as $row) {
		$cfgQobuz[$row['param']] = $row['value'];
	}

	$device = $_SESSION['audioout'] == 'Local' ? '_audioout' : 'btstream';
	$volMode = $_SESSION['mpdmixer'] == 'none' ? 'locked' : 'software';

	// QConnect
	sysCmd('pibuz qconnect enable');
	sysCmd('pibuz settings set qconnect.device_name "' . $_SESSION['qobuzname'] . '"');
	sysCmd('pibuz settings set qconnect.pairing on');
	sysCmd('pibuz settings set qconnect.volume_mode ' . $volMode);
	sysCmd('pibuz settings set qconnect.initial_volume ' . $cfgQobuz['initial_volume']);
	// Playback
	sysCmd('pibuz settings set playback.quality ' . $cfgQobuz['quality']);
	sysCmd('pibuz settings set playback.persist_session false');
	sysCmd('pibuz settings set playback.resume_playback_position false');
	sysCmd('pibuz settings set playback.mpris false');
	// Audio output
	sysCmd('pibuz settings set audio.device "' . $device . '"');
	sysCmd('pibuz settings set audio.backend alsa');
	sysCmd('pibuz settings set audio.alsa_plugin hw');
	sysCmd('pibuz settings set audio.alsa_hardware_volume false');	// Moode does support hardware volume for renderers
	sysCmd('pibuz settings set audio.alsa_mixer_device auto');
	// Audio other
	sysCmd('pibuz settings set audio.stream_buffer_seconds ' . $cfgQobuz['stream_buffer_seconds']);
	sysCmd('pibuz settings set audio.stream_window_seconds ' . $cfgQobuz['stream_window_seconds']);
	sysCmd('pibuz settings set audio.normalization_enabled ' . $cfgQobuz['normalization_enabled']);
	sysCmd('pibuz settings set audio.gapless_enabled ' . $cfgQobuz['gapless_enabled']);
	sysCmd('pibuz settings set audio.streaming_only ' . $cfgQobuz['streaming_only']);
	sysCmd('pibuz settings set audio.stream_first_track ' . $cfgQobuz['stream_first_track']);
	sysCmd('pibuz settings set audio.cache_to_disk ' . $cfgQobuz['cache_to_disk']);
	sysCmd('pibuz settings set audio.memory_cache_mb ' . $cfgQobuz['memory_cache_mb']);
	sysCmd('pibuz settings set audio.alsa_buffer_ms ' . $cfgQobuz['alsa_buffer_ms']);
	sysCmd('pibuz settings set audio.dac_keepalive_ms ' . $cfgQobuz['dac_keepalive_ms']);
	sysCmd('pibuz settings set audio.pcm_ring_ms ' . $cfgQobuz['pcm_ring_ms']);
	sysCmd('pibuz settings set audio.writer_rt_priority ' . $cfgQobuz['writer_rt_priority']);
	// Event script
	sysCmd('pibuz settings set hooks.script /var/local/www/commandw/qbzevent.sh');
}
function startQobuz() {
	// Logging
	$logging = $_SESSION['debuglog'] == '1' ? ' > ' . PIBUZ_LOG : ' > /dev/null';

	cfgQobuz();

	// Start the daemon
	$cmd = 'pibuz run' . $logging . ' 2>&1 &';
	debugLog('startQobuz(): (' . $cmd . ')');
	sysCmd($cmd);

	// Wait for the control API to come up (up to 5 secs)
	for ($i = 0; $i < 10; $i++) {
		usleep(500000);
		$result = sysCmd('curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:8182/api/status');
		if (!empty($result) && $result[0] == '200') {
			break;
		}
	}
}
function stopQobuz() {
	sysCmd('killall pibuz 2> /dev/null');
	for ($i = 0; $i < 15; $i++) {
		if (empty(sysCmd('pgrep -x pibuz'))) {
			break;
		}
		usleep(200000);
	}
	sysCmd('killall -s9 pibuz 2> /dev/null');

	// Local
	sysCmd('/var/www/util/vol.sh -restore');
	if (CamillaDSP::isMPD2CamillaDSPVolSyncEnabled()) {
		sysCmd('systemctl restart mpd2cdspvolume');
	}
	// Multiroom receivers
	if ($_SESSION['multiroom_tx'] == "On" ) {
		updReceiverVol('-restore');
	}

	phpSession('write', 'qbzactive', '0');
	$GLOBALS['qbzactive'] = '0';
	sendFECmd('qbzactive0');
}
function isQobuzInstalled() {
	$installedVersion = sysCmd('dpkg-query --showformat=\'${Version}\n\' --show pibuz | grep moode')[0];
	return (empty($installedVersion) ? false : true);
}
function isQobuzUpgradable() {
	$installedVersion = sysCmd('dpkg-query --showformat=\'${Version}\n\' --show pibuz | grep moode')[0];
	$availableVersion = sqlQuery("SELECT version FROM cfg_plugin WHERE component='renderer' AND type='qobuz-connect'", sqlConnect())[0]['version'];
	return ($installedVersion == $availableVersion ? false : true);
}
function isPibuzInstalled() {
	$result = sysCmd('which pibuz');
	return empty($result) ? false : true;
}
function pibuzVersion() {
	return sysCmd('pibuz --version | awk \'{print $2}\'')[0];
}
function downloadQbzLogs($dbh) {
	$bundleName = 'qobuz-connect-' . $_SESSION['hostname'] . '-' . date('Ymd-His');
	$workDir = '/tmp/' . $bundleName;
	$archive = $workDir . '.tar.gz';

	// The report carries what is NOT already a file: the daemon's own view, the
	// settings moOde pushed, and the audio chain those settings landed in.
	$report = array();
	$report[] = 'QOBUZ CONNECT DIAGNOSTICS';
	$report[] = 'Debug logging    ' . ($_SESSION['debuglog'] == '1' ? 'On' : 'Off: ALERT, Captured log data is not valid');
	$report[] = 'Collected        ' . date('Y-m-d H:i:s T');
	$report[] = 'Pi model         ' . $_SESSION['hdwrrev'];
	$report[] = 'Moode release    ' . getMoodeRel('verbose');
	$report[] = 'Pibuz version     ' . pibuzVersion();
	$report[] = 'Renderer         ' . ($_SESSION['qobuzsvc'] == '1' ? 'On' : 'Off');
	$report[] = 'Audio output     ' . $_SESSION['audioout'];
	$report[] = 'ALSA device      ' . $_SESSION['alsa_output_mode'];
	$report[] = 'DSP              CamillaDSP=' . $_SESSION['camilladsp'] .
		' GraphicEQ=' . $_SESSION['alsaequal'] .
		' ParametricEQ=' . $_SESSION['eqfa12p'] .
		' PolarityInv=' . $_SESSION['invert_polarity'] .
		' Crossfeed=' . $_SESSION['crossfeed'];
	$report[] = 'Other            PeppyALSA=' . ($_SESSION['enable_peppyalsa'] == '1' ? 'On' : 'Off');

	$report[] = '';
	$report[] = '--- Moode settings (cfg_qobuz) ---';
	foreach (sqlRead('cfg_qobuz', $dbh) as $row) {
		$report[] = sprintf('%-26s %s', $row['param'], $row['value']);
	}

	foreach (array(
		'--- Pibuz status ---' => 'pibuz status',
		'--- Pibuz settings ---' => 'pibuz settings show',
		'--- Audio devices ---' => 'aplay -l',
		'--- Memory ---' => 'free -m',
		'--- Pibuz process ---' => 'ps -eo pid,rss,etime,comm | grep -E "pibuz|RSS"',
	) as $heading => $cmd) {
		$report[] = '';
		$report[] = $heading;
		$report = array_merge($report, sysCmd($cmd));
	}

	// $workDir is made by the web user so PHP can write the report into it; the
	// logs are root-owned, so they come across through sysCmd.
	sysCmd('rm -rf ' . $workDir . ' ' . $archive);
	@mkdir($workDir, 0755, true);
	file_put_contents($workDir . '/report.txt', implode("\n", $report) . "\n");
	foreach (array(PIBUZ_LOG, QBZEVENT_LOG, MOODE_LOG) as $log) {
		sysCmd('cp -f ' . $log . ' ' . $workDir . '/');
	}
	sysCmd('chmod -R a+r ' . $workDir);
	sysCmd('tar -czf ' . $archive . ' -C /tmp ' . $bundleName);
	sysCmd('rm -rf ' . $workDir);

	if (!file_exists($archive)) {
		// Notify while the session is still open, or the message is lost.
		$_SESSION['notify']['title'] = NOTIFY_TITLE_ALERT;
		$_SESSION['notify']['msg'] = 'Could not collect the diagnostics. Download cancelled.';
		phpSession('close');
	} else {
		phpSession('close');

		header('Content-Description: File Transfer');
		header('Content-Type: application/gzip');
		header('Content-Transfer-Encoding: binary');
		header('Content-Disposition: attachment; filename="' . $bundleName . '.tar.gz"');
		header('Content-Length: ' . filesize($archive));
		header('Pragma: no-cache');
		header('Expires: 0');
		readfile($archive);
		sysCmd('rm -f ' . $archive);
		exit();
	}
}

// UPnP
function startUPnP() {
	sysCmd('systemctl start upmpdcli');
}
function stopUPnP() {
	sysCmd('systemctl stop upmpdcli');
}

// Squeezelite
function startSqueezeLite() {
	sysCmd('mpc stop');

	if ($_SESSION['alsavolume'] != 'none') {
		sysCmd('/var/www/util/sysutil.sh set-alsavol ' . '"' . $_SESSION['amixname']  . '" ' . $_SESSION['alsavolume_max']);
	}

	sysCmd('systemctl start squeezelite');
}
function stopSqueezeLite() {
	sysCmd('systemctl stop squeezelite');

	sysCmd('/var/www/util/vol.sh -restore');
	if (CamillaDSP::isMPD2CamillaDSPVolSyncEnabled()) {
		sysCmd('systemctl restart mpd2cdspvolume');
	}

	phpSession('write', 'slactive', '0');
	$GLOBALS['slactive'] = '0';
	sendFECmd('slactive0');
}
function cfgSqueezelite() {
	$result = sqlRead('cfg_sl', sqlConnect());

	foreach ($result as $row) {
		$data .= $row['param'] . '=' . $row['value'] . "\n";
	}

	$fh = fopen('/etc/squeezelite.conf', 'w');
	fwrite($fh, $data);
	fclose($fh);
}

// Plexamp
function startPlexamp() {
	sysCmd('mpc stop');
	sysCmd('systemctl start plexamp');
}
function stopPlexamp() {
	sysCmd('systemctl stop plexamp');
	sysCmd('/var/www/util/vol.sh -restore');
	phpSession('write', 'paactive', '0');
	$GLOBALS['paactive'] = '0';
	sendFECmd('paactive0');
}

// RoonBridge
function startRoonBridge() {
	sysCmd('mpc stop');
	sysCmd('systemctl start roonbridge');
}
function stopRoonBridge() {
	sysCmd('systemctl stop roonbridge');
	sysCmd('/var/www/util/vol.sh -restore');
	phpSession('write', 'rbactive', '0');
	$GLOBALS['rbactive'] = '0';
	sendFECmd('rbactive0');
}

// Stop all renderers
function stopAllRenderers() {
	$renderers = array(
		'btsvc'		 => 'stopBluetooth',
		'airplaysvc' => 'stopAirPlay',
		'spotifysvc' => 'stopSpotify',
		'qobuzsvc'	 => 'stopQobuz',
		'upnpsvc'	 => 'stopUPnP',
		'slsvc'		 => 'stopSqueezeLite',
		'pasvc'		 => 'stopPlexamp',
		'rbsvc'		 => 'stopRoonBridge'
	);

	// Watchdog (so monitored renderers are not auto restarted)
	sysCmd('killall -s9 watchdog.sh');
	workerLog('stopAllRenderers(): watchdog stopped');

	// Renderers
	foreach ($renderers as $svc => $stopFunction) {
		if ($_SESSION[$svc] == '1') {
			$stopFunction();
			workerLog('stopAllRenderers(): ' . $svc . ' stopped');
		}
	}
}

// SendSpin Multi-Room Audio renderer functions

function getSendspinStatus() {
	// Streaming if any sendspin process holds a PCM device open.
	// NOTE: do not hardcode /dev/snd/pcmC0D0p (wrong on any non-card-0
	// device) and do not substring-match PIDs (PID 12 matches PID 123).
	// /proc/<pid>/fd gives exact per-process device ownership instead.
	$result = sysCmd('systemctl is-active sendspin 2>/dev/null');
	$status = (!empty($result) && isset($result[0])) ? $result[0] : 'inactive';
	if ($status === 'active') {
		$sendspinPids = sysCmd('pgrep -x sendspin 2>/dev/null');
		foreach ($sendspinPids as $pid) {
			$pid = trim($pid);
			if ($pid === '' || !ctype_digit($pid)) {
				continue;
			}
			foreach (glob('/proc/' . $pid . '/fd/*') ?: array() as $fd) {
				$target = @readlink($fd);
				if (is_string($target) && strncmp($target, '/dev/snd/pcm', 13) === 0) {
					return 'streaming';
				}
			}
		}
		return 'ready';
	}
	return 'inactive';
}

function startSendspin() {
	// Save MPD state before starting
	// moOde pattern: grep the state line. `mpc status` line[0] is the CURRENT
	// SONG, not the state, so indexing [0] always reported "not playing" and
	// the Resume-MPD feature could never fire.
	$mpdWasPlaying = !empty(sysCmd('mpc status | grep -F "[playing]"'));
	
	// Persist in database (survives PHP-FPM restarts)
	$dbh = sqlConnect();
	sqlUpdate('cfg_system', $dbh, 'sendspin_mpd_was_playing', $mpdWasPlaying ? '1' : '0');
	
	// Also write to session for immediate access
	phpSession('write', 'mpd_was_playing', $mpdWasPlaying ? '1' : '0');

	// Stop MPD to release ALSA device
	sysCmd('mpc stop');

	// Start SendSpin daemon
	sysCmd('systemctl start sendspin');
	sysCmd('systemctl enable sendspin');

	// Set active state
	phpSession('write', 'sspactive', '1');
	$GLOBALS['sspactive'] = '1';
	sendFECmd('sspactive1');

	workerLog('startSendspin(): daemon started (MPD was playing: ' . ($mpdWasPlaying ? 'yes' : 'no') . ')');
}

function stopSendspin() {
	// Stop SendSpin daemon
	sysCmd('systemctl stop sendspin');
	sysCmd('systemctl disable sendspin');

	// Optionally resume MPD if it was playing AND rsmafterss is enabled
	$dbh = sqlConnect();
	$result = sqlQuery("SELECT value FROM cfg_system WHERE param='rsmafterss'", $dbh);
	$rsmafterss = (!empty($result)) ? $result[0]['value'] : 'No';
	
	$mpdWasPlaying = $_SESSION['mpd_was_playing'] ?? '0';
	// Also check database as fallback
	if ($mpdWasPlaying == '0') {
		$result = sqlQuery("SELECT value FROM cfg_system WHERE param='sendspin_mpd_was_playing'", $dbh);
		$mpdWasPlaying = (!empty($result)) ? $result[0]['value'] : '0';
	}

	if ($mpdWasPlaying == '1' && $rsmafterss == 'Yes') {
		sleep(1); // Allow SendSpin to release device
		sysCmd('mpc play');
		phpSession('write', 'mpd_was_playing', '0');
		sqlUpdate('cfg_system', $dbh, 'sendspin_mpd_was_playing', '0');
		workerLog('stopSendspin(): MPD playback resumed (rsmafterss=Yes)');
	} elseif ($mpdWasPlaying == '1') {
		// Clear the flag even if not resuming
		phpSession('write', 'mpd_was_playing', '0');
		sqlUpdate('cfg_system', $dbh, 'sendspin_mpd_was_playing', '0');
		workerLog('stopSendspin(): MPD was playing but rsmafterss=No, not resuming');
	}

	workerLog('stopSendspin(): daemon stopped');

	// Local: restore volume knob
	sysCmd('/var/www/util/vol.sh -restore');
	if (CamillaDSP::isMPD2CamillaDSPVolSyncEnabled()) {
		sysCmd('systemctl restart mpd2cdspvolume');
	}

	// Clear active state
	phpSession('write', 'sspactive', '0');
	$GLOBALS['sspactive'] = '0';
	sendFECmd('sspactive0');
}

// === SendSpin Advanced Functions (Release 2) ===

function getSendspinVersion() {
    $result = sysCmd('sudo /root/.local/share/uv/tools/sendspin/bin/sendspin --version 2>/dev/null');
    $version = (!empty($result) && isset($result[0])) ? trim($result[0]) : 'unknown';
    return $version;
}

function getSendspinMetadata() {
    if (file_exists(SENDSPINMETA_FILE)) {
        $meta = file_get_contents(SENDSPINMETA_FILE);
        return $meta;
    }
    return '';
}

function checkSendspinUpdate() {
    $result = sysCmd('sendspin-version-check.sh 2>/dev/null');
    $json = (!empty($result) && isset($result[0])) ? $result[0] : '{}';
    return $json;
}

function updateSendspin() {
    sysCmd('sudo -u root bash -c "uv tool upgrade sendspin 2>&1 && systemctl restart sendspin" > /tmp/sendspin-update.log 2>&1 &');
    workerLog('updateSendspin(): upgrade launched in background');
    return true;
}

function generateSendspinService($dbh = null) {
    if ($dbh === null) {
        $dbh = sqlConnect();
    }
    $result = sqlRead('cfg_sendspin', $dbh);
    $cfg = array();
    foreach ($result as $row) {
        $cfg[$row['param']] = $row['value'];
    }

    $codec = in_array($cfg['audio_codec'] ?? '', ['flac', 'pcm']) ? $cfg['audio_codec'] : 'flac';
    $rate = in_array($cfg['audio_rate'] ?? '', ['44100', '48000', '96000']) ? $cfg['audio_rate'] : '48000';
    $depth = in_array($cfg['audio_depth'] ?? '', ['16', '24', '32']) ? $cfg['audio_depth'] : '16';
        $log_level = in_array($cfg['log_level'] ?? '', ['DEBUG', 'INFO', 'WARNING', 'ERROR']) ? $cfg['log_level'] : 'INFO';

        $audio_format = "{$codec}:{$rate}:{$depth}:2";

        $service = <<<SVC
    [Unit]
    Description=SendSpin Audio Receiver
    After=network-online.target sound.target avahi-daemon.service
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStartPre=/var/local/www/commandw/sendspin-spspre.sh
    ExecStart=/root/.local/share/uv/tools/sendspin/bin/sendspin daemon --audio-device _audioout --audio-format {$audio_format} --name moode-sendspin \\
        --log-level {$log_level} \\
        --hook-start /var/local/www/commandw/sendspin-metadata.sh \\
        --hook-stop /var/local/www/commandw/sendspin-metadata.sh
    ExecStopPost=/var/local/www/commandw/spspost.sh
    Restart=on-failure
    RestartSec=5
    TimeoutStartSec=30
    Environment="HOME=/root"

LimitRTPRIO=99
LimitMEMLOCK=8388608

[Install]
WantedBy=multi-user.target
SVC;

    $file = '/etc/systemd/system/sendspin.service';
    $tmpfile = '/tmp/sendspin.service.tmp';
    $result = file_put_contents($tmpfile, $service);
    if ($result !== false) {
        chmod($tmpfile, 0644);
        sysCmd("sudo cp {$tmpfile} {$file}");
        sysCmd('sudo systemctl daemon-reload');
        @unlink($tmpfile);

        workerLog('generateSendspinService(): service regenerated from DB config');
        return true;
    }
    workerLog('generateSendspinService(): failed to write temp service file');
    return false;
}
