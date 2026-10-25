#!/usr/bin/env python3
"""
SendSpin Metadata Sink for moOde Audio Player (HA Polling Edition)

Music Assistant does not populate the SendSpin metadata@v1 role fields.
This daemon polls Home Assistant's REST API for the moode_sendspin
media_player entity state and writes track metadata to moOde's metadata
file format.

The HA entity_id is resolved dynamically (see HA_ENTITY_HINTS): Home
Assistant appends suffixes like _2 when a stale twin holds the base name,
so a hardcoded entity_id 404s forever after a rename. The sink polls the
cached entity, re-discovers on consecutive 404s, and backs off on 401s.

There is deliberately no SendSpin websocket listener: Music Assistant does
not populate the metadata role fields, so a listener can only do connection
bookkeeping the HA poll already covers within one interval. HA polling is
the sole data path (removed Oct 2026 after the client_id= -> identity=
API break; see PR).

Requires:
  - Home Assistant accessible at HA_URL with a long-lived access token
  - SendSpin CLI venv Python (for aiosendspin dependency)

Systemd service: sendspin-metadata-sink.service
"""

import asyncio
import glob
import hashlib
import logging
import os
import signal
import sys
import time
import urllib.request
from pathlib import Path

# aiohttp comes from the sendspin-cli venv (system python may lack it).
# Resolved dynamically — the bundled Python version moves with uv updates
# (seen: python3.12 at install time, python3.13 after upgrade).
for _candidate in sorted(glob.glob("/root/.local/share/uv/tools/sendspin/lib/python3.*/site-packages")):
    if _candidate not in sys.path:
        sys.path.insert(0, _candidate)

from aiohttp import ClientSession, ClientTimeout

# --- Configuration ---
META_FILE = "/var/local/www/sendspinmeta.txt"
COVER_DIR = "/var/local/www/imagesw/sendspin-covers"

# Home Assistant configuration
HA_URL = "http://192.168.214.159:8123"
HA_TOKEN = os.environ.get("HA_TOKEN", "")
# Initial hint only — the live entity_id is resolved dynamically (HA appends
# _2/_3 when a stale twin holds the base name; the base name 404s forever
# after such a rename). First 200 wins; cache refreshes on 404s.
HA_ENTITY = "media_player.moode_sendspin_2"
HA_ENTITY_HINTS = [HA_ENTITY, "media_player.moode_sendspin"]
HA_POLL_INTERVAL = 3  # seconds between HA API polls
HA_AUTH_BACKOFF_S = 60  # back off this long after a 401 (bad/expired token)

# Runtime resolution state (module-level so the poll loop shares it).
_cached_ha_entity = HA_ENTITY  # fast path: poll the last-known-good entity
_cache_misses = 0  # consecutive 404s against the cached entity
_auth_backoff_until = 0.0  # monotonic deadline; skip polls while in backoff
_auth_warned = False  # log the 401 warning only once per backoff episode

# moOde metadata format: Title~~~Artist~~~Album~~~Duration~~~CoverPath~~~Codec
CLEARED_META = "~~~SendSpin~~~Stopped~~~0~~~~~~"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("sendspin-meta-sink")


def ensure_dirs():
    Path(META_FILE).parent.mkdir(parents=True, exist_ok=True)
    Path(COVER_DIR).mkdir(parents=True, exist_ok=True)


def sanitise(value):
    if value is None:
        return ""
    return str(value).replace("~~~", " ").replace("\r", "").replace("\n", " ").strip()


def write_meta_file(title, artist, album, duration_s, cover_path, codec="SendSpin"):
    title = sanitise(title) or "Unknown"
    artist = sanitise(artist) or "SendSpin"
    album = sanitise(album)
    # moOde expects duration in seconds
    duration = str(int(duration_s)) if duration_s else "0"
    line = f"{title}~~~{artist}~~~{album}~~~{duration}~~~{cover_path}~~~{codec}"
    try:
        with open(META_FILE, "w") as f:
            f.write(line + "\n")
        os.chmod(META_FILE, 0o644)
        logger.info("Metadata: %s by %s", title, artist)
    except Exception as e:
        logger.error("Write metadata failed: %s", e)


def clear_meta_file():
    try:
        with open(META_FILE, "w") as f:
            f.write(CLEARED_META + "\n")
        os.chmod(META_FILE, 0o644)
        logger.info("Metadata cleared")
    except Exception as e:
        logger.error("Clear metadata failed: %s", e)


def download_cover(artwork_url):
    if not artwork_url:
        return ""
    url_hash = hashlib.md5(artwork_url.encode()).hexdigest()
    cover_file = os.path.join(COVER_DIR, f"cover-{url_hash}.jpg")
    if not os.path.exists(cover_file):
        try:
            urllib.request.urlretrieve(artwork_url, cover_file)
            logger.info("Cover art downloaded")
        except Exception as e:
            logger.warning("Cover download failed: %s", e)
            return ""
    if os.path.exists(cover_file):
        return f"imagesw/sendspin-covers/{os.path.basename(cover_file)}"
    return ""


def cleanup_old_covers(max_keep=50):
    try:
        covers = []
        for f in os.listdir(COVER_DIR):
            if f.startswith("cover-") and f.endswith(".jpg"):
                fpath = os.path.join(COVER_DIR, f)
                covers.append((os.path.getmtime(fpath), fpath))
        covers.sort(reverse=True)
        for _, fpath in covers[max_keep:]:
            os.remove(fpath)
    except Exception:
        pass


def is_meta_file_cleared():
    """Check if metadata file was externally cleared (e.g., by spspost.sh)."""
    try:
        with open(META_FILE, "r") as f:
            content = f.read().strip()
            return content == CLEARED_META
    except (FileNotFoundError, IOError):
        return True


# --- HA Polling State ---
last_title = None
last_artist = None


def _ha_entity_candidates():
    """Yield entity_ids to try, cached winner first, then static hints."""
    seen = set()
    if _cached_ha_entity:
        seen.add(_cached_ha_entity)
        yield _cached_ha_entity
    for hint in HA_ENTITY_HINTS:
        if hint not in seen:
            seen.add(hint)
            yield hint


def _rank_ha_candidate(entity_id, state, attrs):
    """Rank a discovery candidate: playing with title wins, unavailable loses."""
    if "moode" not in entity_id or "sendspin" not in entity_id:
        return -1
    has_title = bool(attrs.get("media_title"))
    if state == "playing" and has_title:
        return 3
    if state == "paused" and has_title:
        return 2
    if has_title:
        return 1
    if state not in ("unavailable", "unknown"):
        return 0
    return -1


async def discover_ha_entity(session, headers):
    """Scan /api/states for the live moode_sendspin entity.

    Returns the best entity_id or None. Runs only on repeated 404s (rename
    or fresh client ID), never on the hot path, so one full-dump fetch per
    rename event is acceptable.
    """
    try:
        url = f"{HA_URL}/api/states"
        async with session.get(url, headers=headers, timeout=ClientTimeout(total=10)) as resp:
            if resp.status == 401:
                return None  # caller handles auth backoff
            if resp.status != 200:
                logger.warning("HA discovery returned status %d", resp.status)
                return None
            states = await resp.json()
    except Exception as e:
        logger.warning("HA discovery failed: %s", e)
        return None

    best, best_rank = None, -1
    for entry in states:
        if not isinstance(entry, dict):
            continue
        entity_id = entry.get("entity_id", "")
        if not entity_id.startswith("media_player."):
            continue
        rank = _rank_ha_candidate(entity_id, entry.get("state"), entry.get("attributes", {}))
        if rank > best_rank:
            best, best_rank = entity_id, rank
    return best


async def poll_ha_metadata(session):
    """Poll Home Assistant for the moode_sendspin state (auto-discovered)."""
    global last_title, last_artist
    global _cached_ha_entity, _cache_misses
    global _auth_backoff_until, _auth_warned

    if not HA_TOKEN:
        logger.error("HA_TOKEN not set - cannot poll Home Assistant")
        return

    if time.monotonic() < _auth_backoff_until:
        return  # 401 backoff active: skip quietly until the deadline passes

    headers = {
        "Authorization": f"Bearer {HA_TOKEN}",
        "Content-Type": "application/json",
    }

    data = None
    try:
        for candidate in _ha_entity_candidates():
            url = f"{HA_URL}/api/states/{candidate}"
            try:
                async with session.get(url, headers=headers, timeout=ClientTimeout(total=5)) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        _cached_ha_entity = candidate
                        _cache_misses = 0
                        break
                    if resp.status == 404:
                        # Entity not present under this name (rename twin) — try next.
                        continue
                    if resp.status == 401:
                        # Bad/expired token: back off, warn once per episode.
                        _auth_backoff_until = time.monotonic() + HA_AUTH_BACKOFF_S
                        if not _auth_warned:
                            logger.warning(
                                "HA API 401 Unauthorized — backing off %ds "
                                "(check HA_TOKEN in the systemd unit)",
                                HA_AUTH_BACKOFF_S,
                            )
                            _auth_warned = True
                        return
                    logger.warning("HA API returned status %d", resp.status)
                    return
            except Exception as e:
                logger.warning("HA poll failed: %s", e)
                return
        else:
            # Every candidate 404d. Count the miss; re-discover (not warn)
            # so a rename heals itself within a few polls.
            _cache_misses += 1
            if _cache_misses >= 2:
                found = await discover_ha_entity(session, headers)
                if found:
                    logger.info("HA entity re-discovered as %s", found)
                    _cached_ha_entity = found
                    _cache_misses = 0
                    return  # pick up metadata on the next poll
            logger.debug("HA moode_sendspin entities all returned 404")
            return
        _auth_warned = False  # a 200 resets the once-per-episode 401 warning
    except Exception as e:
        logger.warning("HA poll failed: %s", e)
        return

    state = data.get("state", "idle")
    attrs = data.get("attributes", {})

    if state not in ("playing", "paused"):
        # Not playing - clear metadata if we had something
        if last_title is not None:
            logger.info("HA state: %s - clearing metadata", state)
            clear_meta_file()
            last_title = None
            last_artist = None
        return

    title = attrs.get("media_title")
    artist = attrs.get("media_artist")
    album = attrs.get("media_album_name")
    duration = attrs.get("media_duration", 0)

    # Get artwork URL - try entity_picture first, fall back to HA proxy
    artwork_url = attrs.get("entity_picture")
    # entity_picture_local is the HA proxy URL (more reliable)
    artwork_url_local = attrs.get("entity_picture_local")
    if artwork_url_local:
        artwork_url = f"{HA_URL}{artwork_url_local}"
    elif artwork_url and not artwork_url.startswith("http"):
        artwork_url = f"{HA_URL}{artwork_url}"

    # Update file if track changed OR if it was cleared externally
    # Always write metadata during playing/paused state to recover
    # from hook script overwrites (sendspin-metadata.sh writes placeholders)
    if title != last_title or artist != last_artist or is_meta_file_cleared():
        logger.info("Track changed: %s by %s (state=%s)", title, artist, state)
        cover_path = download_cover(artwork_url) if state == "playing" else ""
        write_meta_file(title, artist, album, duration, cover_path)
        cleanup_old_covers()
        last_title = title
        last_artist = artist
    elif state == "playing":
        # Track same but file may have been overwritten by hook script.
        # Re-write every poll to ensure real metadata stays in place.
        cover_path = download_cover(artwork_url) if state == "playing" else ""
        write_meta_file(title, artist, album, duration, cover_path)
        last_title = title
        last_artist = artist


async def ha_poll_loop():
    """Continuously poll HA for metadata (sole data path — no listener)."""
    async with ClientSession() as session:
        while True:
            await poll_ha_metadata(session)
            await asyncio.sleep(HA_POLL_INTERVAL)


async def main():
    ensure_dirs()
    clear_meta_file()

    if not HA_TOKEN:
        logger.error("HA_TOKEN environment variable not set!")
        logger.error("Set it in the systemd service file: Environment=\"HA_TOKEN=your_token\"")
        sys.exit(1)

    logger.info("Starting SendSpin Metadata Sink (HA polling mode)")
    logger.info("HA URL: %s, Entity hints: %s", HA_URL, HA_ENTITY_HINTS)

    stop_event = asyncio.Event()

    def signal_handler(sig, frame):
        logger.info("Signal %d received, shutting down", sig)
        stop_event.set()

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # HA polling is the sole data path (no websocket listener).
    poll_task = asyncio.create_task(ha_poll_loop())

    await stop_event.wait()

    logger.info("Stopping...")
    poll_task.cancel()
    clear_meta_file()
    logger.info("Stopped")


if __name__ == "__main__":
    asyncio.run(main())
