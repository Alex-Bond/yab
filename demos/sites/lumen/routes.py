"""Lumen, events like Luma's: a discover list, event pages, a registration
form that asks real questions, and the page that says you're on the list."""
import datetime
import importlib.util
import re
import sys
import threading
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name):
    key = "lumen_" + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, HERE / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[key] = module
        spec.loader.exec_module(module)
    return sys.modules[key]


events = _load("events")
art = _load("art")
views = _load("views")
views.events = events

LOCK = threading.Lock()
REGISTRATIONS = {}
MEDIA = {}
FIELDS = ("name", "email", "company", "job_title", "linkedin", "x_handle", "website",
          "working_on", "hoping_for", "demo_slot", "dietary", "updates", "consent")


def _svg(ctx, key, make):
    if key not in MEDIA:
        svg = make()
        if svg is None:
            return None
        MEDIA[key] = svg.encode("utf-8")
    return ctx.html(MEDIA[key], 200, {"Content-Type": "image/svg+xml; charset=utf-8", "Cache-Control": "public, max-age=3600"})


def _validate(f, ev):
    errors = {}
    if not f.get("name", "").strip():
        errors["name"] = "Please enter your name."
    if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", f.get("email", "").strip()):
        errors["email"] = "Please enter an email address the hosts can reach you at."
    if ev.get("questions") and not f.get("working_on", "").strip():
        errors["working_on"] = "Please tell the hosts what you are working on."
    if ev.get("questions") and not f.get("hoping_for", "").strip():
        errors["hoping_for"] = "Please tell the hosts what you hope to get out of the night."
    if not f.get("consent"):
        errors["consent"] = "Please agree to share your answers so the hosts can review your request."
    return errors


def _ics(ev):
    start, end = events.starts(ev), events.ends(ev)
    stamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Lumen//Events//EN", "BEGIN:VEVENT",
             "UID:%s@lumen.localtest.me" % ev["slug"], "DTSTAMP:%s" % stamp,
             "DTSTART:%s" % start.strftime("%Y%m%dT%H%M%S"), "DTEND:%s" % end.strftime("%Y%m%dT%H%M%S"),
             "SUMMARY:%s" % ev["title"], "LOCATION:%s\\, %s" % (ev["venue"], ev["area"].replace(",", "\\,")),
             "DESCRIPTION:%s" % ev["lede"], "END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(lines) + "\r\n"


def handle(req, ctx):
    path = req.path.rstrip("/") or "/"
    if path.endswith(".py") or path == "/site.json" or "__pycache__" in path:
        return ctx.html(views.not_found(), 404)
    if path.startswith("/assets/") or path in ("/favicon.svg", "/favicon.png", "/apple-touch-icon.png"):
        return None
    if path == "/favicon.ico":
        return ctx.file(HERE / "favicon.png", kind="image/png")
    m = re.match(r"^/media/covers/([a-z0-9-]+)\.svg$", path)
    if m:
        return _svg(ctx, "cover-" + m.group(1), lambda: art.cover(m.group(1))) or ctx.html(views.not_found(), 404)
    m = re.match(r"^/media/maps/([a-z0-9-]+)\.svg$", path)
    if m and m.group(1) in events.BY_SLUG:
        ev = events.BY_SLUG[m.group(1)]
        return _svg(ctx, "map-" + ev["slug"], lambda: art.map_svg(ev["venue"]))

    if path in ("/", "/discover", "/events", "/stockholm"):
        return ctx.html(views.discover(req.query.get("q", "").strip(), req.query.get("tag", "").strip()))
    m = re.match(r"^/e/([a-z0-9-]+)$", path)
    if m:
        body = views.event_page(m.group(1))
        return ctx.html(body) if body else ctx.html(views.not_found(), 404)
    m = re.match(r"^/e/([a-z0-9-]+)/register$", path)
    if m and m.group(1) in events.BY_SLUG:
        slug = m.group(1)
        if req.method == "POST":
            return _register(req, ctx, slug)
        values = None
        edit = req.query.get("edit")
        if edit and edit in REGISTRATIONS:
            values = dict(REGISTRATIONS[edit])
        return ctx.html(views.register_page(slug, values))
    m = re.match(r"^/e/([a-z0-9-]+)/registered/([a-z0-9]+)$", path)
    if m and m.group(1) in events.BY_SLUG:
        return ctx.html(views.done_page(m.group(1), REGISTRATIONS.get(m.group(2))))
    m = re.match(r"^/e/([a-z0-9-]+)/calendar\.ics$", path)
    if m and m.group(1) in events.BY_SLUG:
        ev = events.BY_SLUG[m.group(1)]
        return ctx.html(_ics(ev), 200, {"Content-Type": "text/calendar; charset=utf-8",
                                        "Content-Disposition": 'attachment; filename="%s.ics"' % ev["slug"]})
    if path == "/signin":
        return ctx.html(views.signin())
    if path == "/calendars":
        return ctx.html(views.simple("Calendars", "Calendars", "Follow the people who run the events you like, and their next ones land in your inbox."))
    if path == "/host":
        return ctx.html(views.simple("Host an event", "Host with Lumen", "Pages, approvals, questions and reminders for community events. Free while it stays free for your guests."))
    if path == "/help":
        return ctx.html(views.simple("Help", "Help", "Questions about an event go to its hosts: there is a Contact the hosts link on every event page."))
    return ctx.html(views.not_found(), 404)


def _register(req, ctx, slug):
    f = {k: req.form.get(k, "") for k in FIELDS}
    errors = _validate(f, events.BY_SLUG[slug])
    if errors:
        return ctx.html(views.register_page(slug, f, errors), 422)
    rid = uuid.uuid4().hex[:10]
    with LOCK:
        f["id"] = rid
        f["slug"] = slug
        f["at"] = datetime.datetime.now().isoformat(timespec="seconds")
        REGISTRATIONS[rid] = f
    return ctx.redirect("/e/%s/registered/%s" % (slug, rid))
