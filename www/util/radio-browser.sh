#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 The moOde audio player project / Tim Curtis
# Copyright 2026 RadioBrowser extension   / @rubatron
#	https://github.com/rubatron/RadioBrowser/tree/main
# Copyright 2026 RadioBrowser integration / @Gjuju
#	https://github.com/moode-player/moode/commit/910bee751a1f65fa80b1cd44383bc9450cacba19
#
# Radio Browser maintenance helper.
# Usage: radio-browser.sh [--clear-recents|--fix-permissions|--clear-caches|--check-servers]

RBCACHE="/var/local/www/rb-cache"
RECENT="$RBCACHE/recently_played.json"
IMGCACHE="/var/local/www/imagesw/rb-logos"
API="all.api.radio-browser.info"
UA="moode-radio-browser/1.0"

usage() {
	echo "Usage: $(basename "$0") [--clear-recents|--clear-caches|--check-servers|--fix-permissions]"
	exit 1
}

need_root() {
	[[ $EUID -ne 0 ]] && { echo "Use sudo to run $1" ; exit 1 ; }
}

case "$1" in
	--clear-recents)
		need_root "$1"
		rm -f "$RECENT"
		if [ $? -eq 0 ]; then
			echo "Recently played has been cleared"
		else
			echo "Clear failed on Recents"
		fi
		;;
	--clear-caches)
		need_root "$1"
		# API/response data + logo caches (keeps recently_played.json; use --clear-recents for that)
		find "$RBCACHE" -maxdepth 1 -type f -name '*.json' ! -name 'recently_played.json' -delete 2>/dev/null
		if [ $? -eq 0 ]; then
			# Clear logo image cache
			rm -f "$IMGCACHE"/* 2>/dev/null
			if [ $? -eq 0 ]; then
				echo "Caches have been cleared"
			else
				echo "Clear failed on Logo cache"
			fi
		else
			echo "Clear failed on Data cache"
		fi
		;;
	--check-servers)
		start=$(date +%s%3N)
		result=$(curl --stderr - -fsS --max-time 10 -A "$UA" "https://$API/json/servers")
		rc=$?
		end=$(date +%s%3N)
		if [[ $rc -eq 0 ]]; then
			count=$(echo $result | jq '.[].name' | sort -u | wc -l)
			[[ $count -gt 0 ]] && s="" || s="s"
			echo "$count server$s responded in $((end - start)) ms"
		else
			echo "No response was received"
		fi
		;;
	--fix-permissions)
		need_root "$1"
		mkdir -p "$RBCACHE" "$IMGCACHE"
		chown -R www-data:www-data "$RBCACHE" "$IMGCACHE"
		chmod -R 0775 "$RBCACHE" "$IMGCACHE"
		echo "Permissions fixed on data and logo cache"
		;;
	*)
		usage
		;;
esac
