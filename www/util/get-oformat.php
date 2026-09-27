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

// Get session id
session_id(phpSession('get_sessionid'));

// Get output format
phpSession('open_ro');
echo getALSAOutputFormat() . "\n";
