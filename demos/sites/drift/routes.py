"""Drift, the made-up music service: what its files can't do alone.

    /, /stations, /library, /liked,
    /station/<id>, /mix/<id>, /album/<id>   the app's one page (index.html); it
                                            draws the rest itself, so the music
                                            keeps playing from page to page. An
                                            id the catalog doesn't have answers
                                            404 with the same page, which says so.
    /audio/<track>.m4a                      a track from the cache, made by
                                            make_audio.py the first time this
                                            Mac is asked, served in byte ranges
                                            (WebKit's media loader asks for
                                            them and won't play without 206s).
    /audio/status.json                      whether the music is made; ?wait=1
                                            makes it first, for a demo's setup.

The music lives in ~/Library/Caches/yab-demo/drift (YAB_DRIFT_CACHE to move
it), never in this folder. The first page request starts making whatever is
missing in the background, so by the time someone presses Play it is there.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("drift_make_audio", HERE / "make_audio.py")
music = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(music)

CACHE = Path(os.environ.get("YAB_DRIFT_CACHE") or music.CACHE).expanduser()
SHELL = HERE / "index.html"
PAGES = re.compile(r"^/(?:stations|library|liked)?/?$")
DETAIL = re.compile(r"^/(station|mix|album)/([^/]+)/?$")
AUDIO = re.compile(r"^/audio/([a-z0-9-]+)(?:\.(?:m4a|wav))?$")
RANGE = re.compile(r"^bytes=(\d*)-(\d*)$")


def catalog():
    """assets/catalog.js, whose body is JSON."""
    text = (HERE / "assets" / "catalog.js").read_text()
    return json.loads(text[text.index("{"):text.rindex("}") + 1])


# ---------------------------------------------------------------- the music

_lock = threading.Lock()
_maker = None
_ready = False


def _make(only=None):
    command = [sys.executable, str(HERE / "make_audio.py"), str(CACHE)] + (["--only", only] if only else [])
    began = time.time()
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=900)
        said = (done.stdout.strip().splitlines() or done.stderr.strip().splitlines() or ["?"])[-1]
        sys.stderr.write("drift: %s (%.1f s)\n" % (said, time.time() - began))
    except (OSError, subprocess.SubprocessError) as error:
        sys.stderr.write("drift: making the music failed: %s\n" % error)


def ready():
    global _ready
    if not _ready:
        _ready = not music.stale(CACHE) and all(music.found(CACHE, t) for t in music.IDS)
    return _ready


def warm():
    """Starts making what is missing, once, in the background; the thread doing it, if any."""
    global _maker
    if ready():
        return None
    with _lock:
        if _maker is None or not _maker.is_alive():
            if ready():
                return None
            _maker = threading.Thread(target=_make, name="drift-music", daemon=True)
            _maker.start()
        return _maker


def track(tid):
    """The track's file, made first if this Mac hasn't got it."""
    global _ready
    if ready():
        path = music.found(CACHE, tid)
        if path is not None:
            return path
        _ready = False  # the cache was emptied under us
    maker = warm()
    if maker:
        maker.join(timeout=300)
    path = music.found(CACHE, tid)
    if path is None:
        with _lock:
            path = music.found(CACHE, tid)
            if path is None:
                _make(only=tid)
                path = music.found(CACHE, tid)
    return path


def audio(req, ctx, tid):
    path = track(tid)
    if path is None:
        return ctx.json({"error": "The track couldn't be made on this Mac."}, 503)
    reply = ctx.file(path, kind="audio/mp4" if path.suffix == ".m4a" else "audio/wav")
    data, size = reply.body, len(reply.body)
    reply.headers.update({
        "Accept-Ranges": "bytes",
        # The URL carries the music's version (?v=), so a copy may be kept.
        "Cache-Control": "public, max-age=86400",
        "ETag": '"%s-%d-%d"' % (music.VERSION, size, int(path.stat().st_mtime)),
    })
    asked = (req.headers.get("Range") or "").split(",")[0].strip()
    match = RANGE.match(asked) if asked else None
    if not match or not (match.group(1) or match.group(2)):
        return reply
    if match.group(1):
        start = int(match.group(1))
        end = min(int(match.group(2)), size - 1) if match.group(2) else size - 1
    else:
        start, end = max(0, size - int(match.group(2))), size - 1
    if start >= size or start > end:
        reply.status = 416
        reply.headers["Content-Range"] = "bytes */%d" % size
        reply.body = b""
        return reply
    reply.status = 206
    reply.headers["Content-Range"] = "bytes %d-%d/%d" % (start, end, size)
    reply.body = data[start:end + 1]
    return reply


def status(req, ctx):
    if req.query.get("wait"):
        for tid in music.IDS:
            track(tid)
    else:
        warm()
    making = _maker is not None and _maker.is_alive()
    return ctx.json({
        "ready": ready(), "making": making, "version": music.VERSION, "cache": str(CACHE),
        "tracks": {t: (music.found(CACHE, t).name if music.found(CACHE, t) else None) for t in music.IDS},
    })


# ---------------------------------------------------------------- pages

def shell(ctx, status_code=200):
    reply = ctx.file(SHELL, kind="text/html; charset=utf-8")
    reply.status = status_code
    return reply


def handle(req, ctx):
    path = req.path
    if path == "/audio/status.json":
        return status(req, ctx)
    found = AUDIO.match(path)
    if found:
        if found.group(1) not in music.BY_ID:
            return None
        return audio(req, ctx, found.group(1))
    if PAGES.match(path):
        warm()
        return shell(ctx)
    detail = DETAIL.match(path)
    if detail:
        warm()
        kind, key = detail.groups()
        known = catalog()[{"station": "stations", "mix": "mixes", "album": "tracks"}[kind]]
        return shell(ctx, 200 if key in known else 404)
    return None
