#!/usr/bin/env python3
"""
SendSpin Metadata Sink for moOde Audio Player

Connects as a SendSpin client with the metadata@v1 role only (no audio).
Receives track metadata from any SendSpin server and writes it to moOde's
metadata file format for display in the moOde web UI.

Implements the "metadata sink" pattern from the SendSpin client implementation guide:
https://www.sendspin-audio.com/code/

Protocol spec: https://github.com/Sendspin/spec
Library: aiosendspin (installed as dependency of sendspin-cli)

Runs using the sendspin-cli venv Python.
Systemd service: sendspin-metadata-sink.service
"""

import asyncio
import hashlib
import logging
import os
import signal
import sys
import urllib.request
from pathlib import Path

# Use the aiosendspin library from sendspin-cli's venv
VENV_SITE = "/root/.local/share/uv/tools/sendspin/lib/python3.12/site-packages"
sys.path.insert(0, VENV_SITE)

from aiohttp import web
from aiosendspin.client.client import SendspinClient
from aiosendspin.client.listener import ClientListener
from aiosendspin.models.types import Roles

# --- Configuration ---
META_FILE = "/var/local/www/sendspinmeta.txt"
COVER_DIR = "/var/local/www/imagesw/sendspin-covers"
LISTEN_PORT = 8929  # Different from audio daemon (8928)
CLIENT_NAME = "moOde Metadata"
CLIENT_ID = "sendspin-metadata-moOde"

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


def write_meta_file(title, artist, album, duration_ms, cover_path, codec="SendSpin"):
    title = sanitise(title) or "Unknown"
    artist = sanitise(artist) or "SendSpin"
    album = sanitise(album)
    duration = str(int(duration_ms)) if duration_ms else "0"
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


# --- Track the current client connection ---
current_client: SendspinClient | None = None


def on_metadata(payload):
    """Called when server sends metadata updates."""
    meta = getattr(payload, "metadata", None)
    if meta is None:
        return

    title = getattr(meta, "title", None)
    artist = getattr(meta, "artist", None)
    album = getattr(meta, "album", None)
    artwork_url = getattr(meta, "artwork_url", None)

    duration_ms = 0
    progress = getattr(meta, "progress", None)
    if progress is not None:
        duration_ms = getattr(progress, "track_duration", 0) or 0

    cover_path = download_cover(artwork_url)
    write_meta_file(title, artist, album, duration_ms, cover_path)
    cleanup_old_covers()


def on_disconnect():
    """Called when server disconnects."""
    logger.info("Server disconnected")
    clear_meta_file()


async def handle_connection(ws: web.WebSocketResponse) -> None:
    """Handle incoming server connection."""
    global current_client
    logger.info("Server connecting...")

    client = SendspinClient(
        client_id=CLIENT_ID,
        client_name=CLIENT_NAME,
        roles=[Roles.METADATA],  # metadata@v1 only - no audio
    )

    client.add_metadata_listener(on_metadata)
    client.add_disconnect_listener(on_disconnect)

    current_client = client

    try:
        await client.attach_websocket(ws)
        logger.info("Server connected, waiting for metadata...")
        # Keep connection alive until disconnected
        disconnect_event = asyncio.Event()
        client.add_disconnect_listener(disconnect_event.set)
        await disconnect_event.wait()
    except Exception as e:
        logger.error("Connection error: %s", e)
    finally:
        clear_meta_file()
        current_client = None


async def main():
    ensure_dirs()
    clear_meta_file()

    logger.info("Starting SendSpin Metadata Sink on port %d", LISTEN_PORT)

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

    await stop_event.wait()

    logger.info("Stopping...")
    await listener.stop()
    clear_meta_file()
    logger.info("Stopped")


if __name__ == "__main__":
    asyncio.run(main())
