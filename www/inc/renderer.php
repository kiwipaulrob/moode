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
	sysCmd('systemctl start nqptp');

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
		sysCmd('pkill -f -9 shairport-sync');
		$result = sysCmd('pgrep -c -f "LC_ALL=C /usr/bin/shairport-sync"')[0];
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

// Deezer Connect
function startDeezer() {
	$result = sqlRead('cfg_deezer', sqlConnect());
	$cfgDeezer = array();
	foreach ($result as $row) {
		$cfgDeezer[$row['param']] = $row['value'];
	}

	// Output device
	$device = $_SESSION['audioout'] == 'Local' ? '_audioout' : 'btstream'; // <= 0.18.0

	// Options
	$normalization = $cfgDeezer['normalize_volume'] == 'Yes' ? ' --normalize-volume' : '';
	$interruption = $cfgDeezer['no_interruption'] == 'Yes' ? ' --no_interruption' : '';
	$ramCache = $cfgDeezer['max_ram'] == '0' ? '' : ' --max-ram ' . $cfgDeezer['max_ram'];
	$ditherBits = empty($cfgDeezer['dither_bits']) ? '' : ' --dither-bits ' . $cfgDeezer['dither_bits'];
	$rate = '';
	$format = $cfgDeezer['format'];
	// Logging
	$logging = $_SESSION['debuglog'] == '1' ? ' -v > ' . PLEEZER_LOG : ' > /dev/null';

 	// Command
	$cmd = 'pleezer' .
		' --name "' . $_SESSION['deezername'] . '"' .
		' --device-type "' . 'web' . '"' .
		' --device "' . 'ALSA|' . $device . '|' . $rate . '|' . $format . '"' .
		' --initial-volume "' . $cfgDeezer['initial_volume'] . '"' .
		' --secrets "' . DEEZ_CREDENTIALS_FILE . '"' .
		$normalization .
		$interruption .
		$ramCache .
		$ditherBits .
		' --noise-shaping ' . $cfgDeezer['noise_shaping'] .
		' --hook /var/local/www/commandw/deezevent.sh' .
		$logging . ' 2>&1 &';

	debugLog('startDeezer(): (' . $cmd . ')');
	sysCmd($cmd);
}
function stopDeezer() {
	sysCmd('killall -s9 pleezer');

	// Local
	sysCmd('/var/www/util/vol.sh -restore');
	if (CamillaDSP::isMPD2CamillaDSPVolSyncEnabled()) {
		sysCmd('systemctl restart mpd2cdspvolume');
	}
	// Multiroom receivers
	if ($_SESSION['multiroom_tx'] == "On" ) {
		updReceiverVol('-restore');
	}

	phpSession('write', 'deezactive', '0');
	$GLOBALS['deezactive'] = '0';
	sendFECmd('deezactive0');
}
function updateDeezCredentials($email, $password) {
	// Truncate the file
	$fh = fopen(DEEZ_CREDENTIALS_FILE, 'w');
	ftruncate($fh, 0);
	// Write new contents
	$data .= "email = \"" . $email . "\"\n";
	$data .= "password = \"" . $password . "\"\n";
	fwrite($fh, $data);
	fclose($fh);
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
		'deezersvc'  => 'stopDeezer',
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
	// Check systemd service status safely
	$result = sysCmd('systemctl is-active sendspin 2>/dev/null');
	$status = (!empty($result) && isset($result[0])) ? $result[0] : 'inactive';
	if ($status === 'active') {
		// Check if actually streaming (process using audio)
		$sndResult = sysCmd('fuser /dev/snd/pcmC0D0p 2>/dev/null');
		if (!empty($sndResult)) {
			// Check if sendspin is using the device
			$sendspinPids = sysCmd('pgrep -f sendspin 2>/dev/null');
			foreach ($sendspinPids as $pid) {
				if (strpos($sndResult[0], $pid) !== false) {
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
	$mpdStatus = sysCmd('mpc status')[0];
	$mpdWasPlaying = strpos($mpdStatus, 'playing') !== false;
	
	// Persist in database (survives PHP-FPM restarts)
	$dbh = sqlConnect();
	sqlUpdate('cfg_system', $dbh, 'sendspin_mpd_was_playing', $mpdWasPlaying ? '1' : '0');
	
	// Also write to session for immediate access
	phpSession('write', 'mpd_was_playing', $mpdWasPlaying ? '1' : '0');

	// Stop MPD to release ALSA device
	sysCmd('mpc stop');

	// Note: Using direct hardware access
	// ALSA config handled by generateSendspinService() via sendspin.conf

	// Start SendSpin daemon
	sysCmd('systemctl start sendspin');
	sysCmd('systemctl enable sendspin');

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
    sysCmd('sudo -u root bash -c "/root/.local/share/uv/tools/sendspin/bin/python -m uv tool upgrade sendspin 2>&1 && systemctl restart sendspin" > /tmp/sendspin-update.log 2>&1 &');
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
    ExecStart=/root/.local/share/uv/tools/sendspin/bin/sendspin daemon --audio-device sendspin --audio-format {$audio_format} --name moode-sendspin \\
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

        $cardResult = sysCmd("sqlite3 /var/local/www/db/moode-sqlite3.db \"SELECT value FROM cfg_system WHERE param='cardnum'\" 2>/dev/null");
        $cardnum = (!empty($cardResult) && isset($cardResult[0])) ? trim($cardResult[0]) : '0';
        $alsaConf = "pcm.sendspin {\ntype plug\nslave {\npcm \"plughw:{$cardnum},0\"\n}\n}\n";
        $alsaTmp = '/tmp/sendspin.alsa.tmp';
        if (file_put_contents($alsaTmp, $alsaConf) !== false) {
            chmod($alsaTmp, 0644);
            sysCmd("sudo cp {$alsaTmp} /etc/alsa/conf.d/sendspin.conf");
            @unlink($alsaTmp);
        }

        workerLog('generateSendspinService(): service + alsa conf regenerated from DB config');
        return true;
    }
    workerLog('generateSendspinService(): failed to write temp service file');
    return false;
}
