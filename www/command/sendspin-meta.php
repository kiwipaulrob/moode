<?php
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SendSpin metadata endpoint — serves now-playing info to JS poller
 */

$sspFile = '/var/local/www/sendspinmeta.txt';

if (file_exists($sspFile)) {
    $raw = trim(file_get_contents($sspFile));
    if ($raw === '') {
        echo '';
        exit;
    }
    // Try JSON format (from metadata sink/hook)
    $json = json_decode($raw, true);
    if ($json && isset($json['title'])) {
        echo implode('~~~', [
            $json['title'] ?? '',
            $json['artist'] ?? '',
            $json['album'] ?? '',
            '', // track number
            $json['artwork_url'] ?? ''
        ]);
    } else {
        // Plain text fallback (~~~ separated)
        echo $raw;
    }
} else {
    echo '';
}