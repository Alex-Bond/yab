"""Roundtable's rooms: every /r/<room> is the one call page, room.html."""
import re

ROOM = re.compile(r"^/r/[A-Za-z0-9][A-Za-z0-9._-]{0,80}/?$")


def handle(req, ctx):
    if ROOM.match(req.path):
        return ctx.html((ctx.folder / "room.html").read_text(encoding="utf-8"))
    if req.path in ("/r", "/r/"):
        return ctx.redirect("/")
    return None
