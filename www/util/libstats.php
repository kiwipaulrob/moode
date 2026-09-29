#!/usr/bin/php
<?php
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2014 The moOde audio player project / Tim Curtis
*/

require_once __DIR__ . '/../inc/common.php';
require_once __DIR__ . '/../inc/session.php';
require_once __DIR__ . '/../inc/sql.php';
require_once __DIR__ . '/../inc/mpd.php';

// Analyze the MPD database and produce artist/album/track counts
if (false === ($sock = openMpdSock('localhost', 6600))) {
	workerLog('CRITICAL ERROR: libstats.php: Connection to MPD failed');
} else {
	// Get session id
	session_id(phpSession('get_sessionid'));

	// Initialize counts
	$trackCount = 0;
	$albumCount = 0;
	$artistCount = 0;
	$artists = array();
	$albumKeys = array();
	phpSession('open');
	$_SESSION['mpd_dbanalyze_count'] = 0;
	phpSession('close');

	// Generate the file list
	$fileList = sysCmd("mpc search '(Title !=\"\")'");

	// Scan the file list and generate the counts
	foreach ($fileList as $file) {
		sendMpdCmd($sock, 'lsinfo "' . escapeDblQuotes($file) . '"');
		$tags = parseLsinfoAsArray(readMpdResp($sock));

		// ALBUMS: Accumulate unique album keys
		// AlbumPath (to accurately differentiate albums)
		$aPath = explode("/", $file);
		$removeFromHere = -1; // Remove the filename
		if (str_ends_with($aPath[count($aPath) - 2], ".cue") == true) {
			$removeFromHere = -2; // Remove the cue filename
		}
		array_splice($aPath, $removeFromHere);
		$albumPath = join("/", $aPath);
		// Album and AlbumArtist
		$album = $tags['Album'] ? $tags['Album'] : 'Unknown Album';
		$albumartist = $tags['AlbumArtist'] ? $tags['AlbumArtist'] :
			($tags['Artist'] ? (count($tags['Artist']) == 1 ? $tags['Artist'][0] :
			'Unknown AlbumArtist') : 'Unknown AlbumArtist');
		// Create unique album keys
		$albumKey = $album . '@' . $albumartist . '@' . $albumPath;
		if  (!in_array($albumKey, $albumKeys)) {
			array_push($albumKeys, $albumKey);
		}

		// ARTISTS: Accumulate unique artists
		foreach($tags['Artist'] as $artist) {
			if  (!in_array($artist, $artists)) {
				array_push($artists, $artist);
			}
		}

		// TRACKS: File count
		$trackCount++;


		// Update global count every 10 files
		if ($trackCount % 10 == 0) {
			phpSession('open');
			$_SESSION['mpd_dbanalyze_count'] = $trackCount;
			phpSession('close');
		}
	}
	// Final counts
	$finalCounts = 'Artists:' . count($artists) . ' Albums:' . count($albumKeys) . ' Tracks:' . $trackCount;
	phpSession('open');
	$_SESSION['mpd_dbanalyze_count'] = $finalCounts;
	phpSession('close');

	// Hide busy spinner
	sendFECmd('libanalyze_done');

	// Console output
	echo $finalCounts . "\n";
}
