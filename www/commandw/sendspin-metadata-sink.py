#!/usr/bin/env python3
"""
SendSpin Metadata Sink for moOde Audio Player (Multi-Source Edition)

Metadata sources in priority order:
  1. SendSpin protocol metadata@v1 role — works with any sender that populates it
  2. Music Assistant REST API — works when MA is the sender (no auth needed)
  3. Streaming status fallback — marks "SendSpin" when a stream is active

No external dependencies beyond sendspin CLI + MA network access.
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

# Use the aiosendspin library from sendspin-cli's venv
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

# Music Assistant configuration (fallback source)
MA_URL = os.environ.get("MA_URL", "http://192.168.214.30:8095")
MA_POLL_INTERVAL = 5  # seconds between MA API polls (less frequent than protocol)

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
    duration = str(int(duration_s)) if duration_s else "0"
    line = f"{title}~~~{artist}~~~{album}~~~{duration}~~~{cover_path}~~~{codec}"
    try:
        with open(META_FILE, "w") as f:
            f.write(line + "\n")
        os.chmod(META_FILE, 0o644)
        logger.info("Metadata: %s by %s", title, artist)
    except Exception as e:
        logger.error("Write metadata failed: %s", e)


def write_streaming_status():
    """Write minimal metadata when streaming but no source has track info."""
    try:
        with open(META_FILE, "w") as f:
            f.write("SendSpin~~~Streaming~~~ ~~~0~~~~~~\n")
        os.chmod(META_FILE, 0o644)
        logger.debug("Streaming status written (no track metadata available)")
    except Exception as e:
        logger.error("Write status failed: %s", e)


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


# --- Global state ---
last_title = None
last_artist = None
is_streaming = False
protocol_meta_active = False  # True when protocol metadata was received


# ============================================================================
# Source 1: SendSpin protocol metadata@v1 (primary, real-time)
# ============================================================================

def on_metadata(payload):
    """Called when SendSpin server pushes metadata via the protocol."""
    global last_title, last_artist, protocol_meta_active

    meta = getattr(payload, "metadata", None)
    if meta is None:
        return

    title = getattr(meta, "title", None) or getattr(meta, "name", None)
    artist = getattr(meta, "artist", None) or ",".join(getattr(meta, "artists", []))
    album = getattr(meta, "album", None)
    duration = getattr(meta, "duration", 0)
    cover_url = getattr(meta, "image_url", None) or getattr(meta, "artwork_url", None) or getattr(meta, "cover_url", None)

    if not title:
        logger.debug("Protocol metadata received but no title — falling back")
        return

    logger.info("Protocol metadata: %s by %s", title, artist)
    protocol_meta_active = True

    cover_path = download_cover(cover_url) if cover_url else ""
    write_meta_file(title, artist, album, duration, cover_path, "SendSpin")
    last_title = title
    last_artist = artist


# ============================================================================
# Source 2: Music Assistant REST API (fallback, polled)
# ============================================================================

def is_meta_file_cleared():
    """Check if metadata file was externally cleared (e.g., by spspost.sh) or overwritten by hook."""
    try:
        with open(META_FILE, "r") as f:
            content = f.read().strip()
            # Cleared by spspost.sh
            if content == CLEARED_META:
                return True
            # Overwritten by hook script (JSON format, not ~~~ format)
            if content.startswith("{") and "status" in content:
                return True
            return False
    except (FileNotFoundError, IOError):
        return True


async def poll_ma_metadata(session):
    """Poll Music Assistant for currently playing track on any player."""
    global last_title, last_artist, protocol_meta_active

    # If protocol metadata is active, no need to poll MA
    if protocol_meta_active:
        return

    try:
        async with session.get(
            f"{MA_URL}/api/players",
            timeout=ClientTimeout(total=5)
        ) as resp:
            if resp.status != 200:
                logger.debug("MA API returned %d", resp.status)
                return
            players = await resp.json()
    except Exception as e:
        logger.debug("MA poll failed: %s", e)
        return

    # Find a player that is actively playing
    for player in players:
        if player.get("active") and player.get("state") == "playing":
            item = player.get("current_item") or {}
            title = item.get("name", "")
            artists = item.get("artists", [])
            artist = artists[0] if artists else ""
            album_name = (item.get("album") or {}).get("name", "")
            duration = item.get("duration", 0)
            image_url = item.get("image_url", "")

            if not title:
                continue

            if title != last_title or artist != last_artist or is_meta_file_cleared():
                logger.info("MA metadata: %s by %s", title, artist)
                cover_path = download_cover(image_url) if image_url else ""
                write_meta_file(title, artist, album_name, duration, cover_path, "SendSpin")
                cleanup_old_covers()
                last_title = title
                last_artist = artist
            return  # Found a playing player, done

    # No playing player found — if still streaming, write status
    if is_streaming and is_meta_file_cleared():
        write_streaming_status()


async def ma_poll_loop():
    """Continuously poll MA for metadata when protocol metadata isn't active."""
    async with ClientSession() as session:
        while True:
            await poll_ma_metadata(session)
            await asyncio.sleep(MA_POLL_INTERVAL)


# ============================================================================
# Stream state monitoring (connection lifecycle)
# ============================================================================

def on_disconnect():
    """Called when server disconnects."""
    global is_streaming, last_title, last_artist, protocol_meta_active
    logger.info("Server disconnected")
    is_streaming = False
    protocol_meta_active = False
    clear_meta_file()
    last_title = None
    last_artist = None


def on_stream_start(message):
    """Called when audio stream starts."""
    global is_streaming, protocol_meta_active
    is_streaming = True
    protocol_meta_active = False  # Reset — new stream may not send protocol metadata
    logger.info("Stream started")


def on_stream_end(roles):
    """Called when audio stream ends."""
    global is_streaming, last_title, last_artist, protocol_meta_active
    is_streaming = False
    protocol_meta_active = False
    logger.info("Stream ended — clearing metadata")
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


# ============================================================================
# Main — starts without requiring any external tokens
# ============================================================================

async def main():
    ensure_dirs()
    clear_meta_file()

    logger.info("Starting SendSpin Metadata Sink (multi-source mode)")
    logger.info("  Primary:  SendSpin protocol metadata@v1")
    logger.info("  Fallback: Music Assistant API (%s)", MA_URL)
    logger.info("  Listener: port %d", LISTEN_PORT)

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

    # Start MA polling loop (only polls when protocol metadata isn't active)
    poll_task = asyncio.create_task(ma_poll_loop())

    await stop_event.wait()

    logger.info("Stopping...")
    poll_task.cancel()
    await listener.stop()
    clear_meta_file()
    logger.info("Stopped")


if __name__ == "__main__":
    asyncio.run(main())
