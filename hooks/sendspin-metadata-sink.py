#!/usr/bin/env python3
"""
SendSpin Metadata Sink for moOde Audio Player (HA Polling Edition)

Music Assistant does not populate the SendSpin metadata@v1 role fields.
This daemon polls Home Assistant's REST API for the media_player.moode_sendspin
entity state and writes track metadata to moOde's metadata file format.

The SendSpin listener is kept for connection monitoring (so we know when
a server connects/disconnects), but actual track data comes from HA.

Requires:
  - Home Assistant accessible at HA_URL with a long-lived access token
  - SendSpin CLI venv Python (for aiosendspin dependency)

Systemd service: sendspin-metadata-sink.service
"""

import asyncio
import hashlib
import json
import logging
import os
import signal
import sys
import urllib.request
from pathlib import Path

# Use the aiosendspin library from sendspin-cli's venv (for connection monitoring)
VENV_SITE = "/root/.local/share/uv/tools/sendspin/lib/python3.12/site-packages"
sys.path.insert(0, VENV_SITE)

from aiohttp import web, ClientSession, ClientTimeout
from aiosendspin.client.client import SendspinClient
from aiosendspin.client.listener import ClientListener
from aiosendspin.models.types import Roles

# --- Configuration ---
META_FILE = "/var/local/www/sendspinmeta.txt"
COVER_DIR = "/var/local/www/imagesw/sendspin-covers"
LISTEN_PORT = 8929  # Different from audio daemon (8928)
CLIENT_NAME = "moOde Metadata"
CLIENT_ID = "sendspin-metadata-moOde"

# Home Assistant configuration
HA_URL = "http://192.168.214.159:8123"
HA_TOKEN = os.environ.get("HA_TOKEN", "")
HA_ENTITY = "media_player.moode_sendspin"
HA_POLL_INTERVAL = 3  # seconds between HA API polls

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
is_streaming = False


async def poll_ha_metadata(session):
    """Poll Home Assistant for media_player.moode_sendspin state."""
    global last_title, last_artist

    if not HA_TOKEN:
        logger.error("HA_TOKEN not set - cannot poll Home Assistant")
        return

    url = f"{HA_URL}/api/states/{HA_ENTITY}"
    headers = {
        "Authorization": f"Bearer {HA_TOKEN}",
        "Content-Type": "application/json",
    }

    try:
        async with session.get(url, headers=headers, timeout=ClientTimeout(total=5)) as resp:
            if resp.status != 200:
                logger.warning("HA API returned status %d", resp.status)
                return
            data = await resp.json()
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
    # (spspost.sh clears the file on sendspin stop, but the same track
    #  may still be playing when sendspin restarts)
    if title != last_title or artist != last_artist or is_meta_file_cleared():
        logger.info("Track changed: %s by %s (state=%s)", title, artist, state)
        cover_path = download_cover(artwork_url) if state == "playing" else ""
        write_meta_file(title, artist, album, duration, cover_path)
        cleanup_old_covers()
        last_title = title
        last_artist = artist
    # else: same track, no need to rewrite the file


async def ha_poll_loop():
    """Continuously poll HA for metadata - always running, not gated on stream state."""
    async with ClientSession() as session:
        while True:
            await poll_ha_metadata(session)
            await asyncio.sleep(HA_POLL_INTERVAL)


# --- SendSpin connection monitoring (for stream start/stop detection) ---
def on_metadata(payload):
    """Called when server sends metadata updates - logged but not used for display."""
    meta = getattr(payload, "metadata", None)
    if meta is not None:
        logger.debug("SendSpin metadata (unused): title=%s artist=%s",
                     getattr(meta, "title", None), getattr(meta, "artist", None))


def on_disconnect():
    """Called when server disconnects."""
    global is_streaming, last_title, last_artist
    logger.info("Server disconnected")
    is_streaming = False
    clear_meta_file()
    last_title = None
    last_artist = None


def on_stream_start(message):
    """Called when audio stream starts."""
    global is_streaming
    is_streaming = True
    logger.info("Stream started - HA polling active")


def on_stream_end(roles):
    """Called when audio stream ends."""
    global is_streaming, last_title, last_artist
    is_streaming = False
    logger.info("Stream ended - clearing metadata")
    clear_meta_file()
    last_title = None
    last_artist = None


async def handle_connection(ws: web.WebSocketResponse) -> None:
    """Handle incoming server connection."""
    logger.info("Server connecting...")

    client = SendspinClient(
        client_id=CLIENT_ID,
        client_name=CLIENT_NAME,
        roles=[Roles.METADATA],
    )

    client.add_metadata_listener(on_metadata)
    client.add_disconnect_listener(on_disconnect)
    client.add_stream_start_listener(on_stream_start)
    client.add_stream_end_listener(on_stream_end)

    try:
        await client.attach_websocket(ws)
        logger.info("Server connected, monitoring stream state...")
        disconnect_event = asyncio.Event()
        client.add_disconnect_listener(disconnect_event.set)
        await disconnect_event.wait()
    except Exception as e:
        logger.error("Connection error: %s", e)
    finally:
        clear_meta_file()


async def main():
    ensure_dirs()
    clear_meta_file()

    if not HA_TOKEN:
        logger.error("HA_TOKEN environment variable not set!")
        logger.error("Set it in the systemd service file: Environment=\"HA_TOKEN=your_token\"")
        sys.exit(1)

    logger.info("Starting SendSpin Metadata Sink (HA polling mode) on port %d", LISTEN_PORT)
    logger.info("HA URL: %s, Entity: %s", HA_URL, HA_ENTITY)

    listener = ClientListener(
        client_id=CLIENT_ID,
        on_connection=handle_connection,
        port=LISTEN_PORT,
        client_name=CLIENT_NAME,
    )

    stop_event = asyncio.Event()

    def signal_handler(sig, frame):
        logger.info("Signal %d received, shutting down", sig)
        stop_event.set()

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    await listener.start()
    logger.info("Listening on port %d, advertising as '%s'", LISTEN_PORT, CLIENT_NAME)

    # Start HA polling loop
    poll_task = asyncio.create_task(ha_poll_loop())

    await stop_event.wait()

    logger.info("Stopping...")
    poll_task.cancel()
    await listener.stop()
    clear_meta_file()
    logger.info("Stopped")


if __name__ == "__main__":
    asyncio.run(main())
