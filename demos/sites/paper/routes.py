"""Paper, a docs editor: /d/<slug> is one template (_t/doc.html) around a
document of docs/<slug>.html, whose first comment holds its title, place,
people and comments as JSON. The home page is plain index.html.
"""
import datetime as dt
import html
import json
import re
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATES = HERE / "_t"
DOCS = HERE / "docs"
STARTED = time.time()

PEOPLE = {
    "ML": "Mira Lindqvist",
    "JB": "Jonas Berg",
    "AE": "Anna Ek",
    "EP": "Elliot Park",
    "SH": "Sara Holm",
}


def esc(value):
    return html.escape(str(value), quote=True)


def render(template, **values):
    text = (TEMPLATES / (template + ".html")).read_text()
    for _ in range(4):
        text, count = re.subn(r"\{\{>\s*([\w-]+)\s*\}\}",
                              lambda m: (TEMPLATES / (m.group(1) + ".html")).read_text(), text)
        if not count:
            break
    text = re.sub(r"\{\{\{\s*(\w+)\s*\}\}\}", lambda m: str(values.get(m.group(1), "")), text)
    return re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: esc(values.get(m.group(1), "")), text)


def world(ctx):
    """When this world was built: a document edited in an older world
    starts over. Without a world file, when this server started."""
    built = ctx.state.get("built")
    if not isinstance(built, (int, float)) or abs(built - time.time()) < 2:
        built = STARTED
    return str(int(built))


def trip(ctx):
    """Mira's Lisbon days, twelve days out, four long (as the world has them)."""
    built = ctx.state.get("built")
    now = built if isinstance(built, (int, float)) else time.time()
    start = dt.date.fromtimestamp(now) + dt.timedelta(days=12)
    end = start + dt.timedelta(days=4)
    day = lambda d: d.strftime("%A, %B ") + str(d.day)
    return day(start), day(end)


def load(slug):
    path = DOCS / (slug + ".html")
    if not re.fullmatch(r"[a-z0-9-]+", slug) or not path.is_file():
        return None
    text = path.read_text()
    found = re.match(r"\s*<!--(.*?)-->", text, re.S)
    meta = json.loads(found.group(1)) if found else {}
    return meta, text[found.end():] if found else text


def avatar(initials, extra=""):
    return '<span class="av av-%s%s" title="%s">%s</span>' % (initials, extra, esc(PEOPLE.get(initials, initials)), initials)


def comments_html(items):
    out = []
    for c in items:
        out.append(
            '<div class="cc" data-for="%(id)s">'
            '<div class="cc-top">%(av)s<b>%(who)s</b><time>%(when)s</time>'
            '<button class="cc-resolve" type="button" title="Resolve"><svg class="i"><use href="#i-check"/></svg></button></div>'
            '<p>%(text)s</p>'
            '<div class="cc-reply"><input type="text" placeholder="Reply or add others with @" aria-label="Reply"></div>'
            '</div>' % {"id": esc(c["id"]), "av": avatar(c["by"]), "who": esc(PEOPLE.get(c["by"], c["by"])),
                        "when": esc(c["when"]), "text": esc(c["text"])})
    return "".join(out)


def doc_page(ctx, slug):
    found = load(slug)
    if not found:
        return None
    meta, body = found
    go, back = trip(ctx)
    body = body.replace("{{trip_start}}", go).replace("{{trip_end}}", back)
    crumbs = "".join('<span class="crumb">%s</span><span class="crumb-sep">/</span>' % esc(c) for c in meta.get("crumbs", []))
    people = "".join(avatar(p, " here" if i == meta.get("here", -1) else "") for i, p in enumerate(meta.get("people", [])))
    items = meta.get("comments", [])
    private = (meta.get("crumbs") or [""])[0] == "Private"
    return render("doc", title=meta.get("title", "Untitled"), crumbs=crumbs, edited=meta.get("edited", ""),
                  people=people, comments=comments_html(items), count=len(items) or "", slug=slug,
                  share_icon="lock" if private else "users",
                  world=world(ctx), body=body, empty="true" if not body.strip() else "false")


def handle(req, ctx):
    path = req.path.rstrip("/") or "/"
    if path.startswith("/_t") or path.startswith("/docs"):
        return ctx.html((HERE / "404.html").read_text(), 404)
    found = re.fullmatch(r"/d/([^/]+)", path)
    if found:
        page = doc_page(ctx, found.group(1))
        if page is None:
            return ctx.html((HERE / "404.html").read_text(), 404)
        return ctx.html(page)
    return None
