"""Lumen's events in Stockholm. Dates are rules, not days: "Thursday next
week, 18:00", worked out from today on the server and again in the page."""
import datetime

# weekday: Monday 0 to Sunday 6. week 0: the next one after today; 1: next
# week's; 2: the week after.
EVENTS = [
    {
        "slug": "design-systems-night", "title": "Design Systems Night · Stockholm", "short": "Design Systems Night",
        "rule": {"wd": 3, "week": 0, "h": 18, "m": 0}, "hours": 3,
        "venue": "Hyllie Studio", "area": "Södermalm, Stockholm", "street": "Bondegatan 21, 116 33 Stockholm",
        "hosts": [["Figure Community Stockholm", "FC", "#6d5dfc", "#ff8a65"], ["Tern Labs", "TL", "#1f8a70", "#9be15d"]],
        "going": 138, "approval": True, "tags": ["Design", "Tech"], "featured": True, "questions": True,
        "lede": "Talks, demos and drinks for people who build and care for design systems.",
    },
    {
        "slug": "founders-and-fika", "title": "Founders & Fika: AI tooling breakfast", "short": "Founders & Fika",
        "rule": {"wd": 4, "week": 0, "h": 8, "m": 0}, "hours": 1.5,
        "venue": "Kafé Lyktan", "area": "Vasastan, Stockholm", "street": "Sankt Eriksgatan 88, 113 62 Stockholm",
        "hosts": [["Stockholm Founders Club", "SF", "#f59e0b", "#ef4444"]],
        "going": 46, "approval": False, "tags": ["AI", "Startups"],
        "lede": "Cinnamon buns and honest notes on the AI tools that actually stuck.",
    },
    {
        "slug": "sunday-run-club", "title": "Sunday Run Club · Djurgården loop", "short": "Sunday Run Club",
        "rule": {"wd": 6, "week": 0, "h": 9, "m": 30}, "hours": 1.5,
        "venue": "Djurgårdsbron", "area": "Djurgården, Stockholm", "street": "Djurgårdsbron, 115 21 Stockholm",
        "hosts": [["Söder Striders", "SS", "#10b981", "#3b82f6"]],
        "going": 81, "approval": False, "tags": ["Wellness"],
        "lede": "An easy 7 km around the island, coffee after. Every pace welcome.",
    },
    {
        "slug": "creative-coding-14", "title": "Creative Coding Stockholm #14", "short": "Creative Coding #14",
        "rule": {"wd": 1, "week": 1, "h": 18, "m": 30}, "hours": 2.5,
        "venue": "Pixel & Pine", "area": "Kungsholmen, Stockholm", "street": "Hantverkargatan 14, 112 21 Stockholm",
        "hosts": [["Creative Coding Stockholm", "CC", "#22d3ee", "#a855f7"]],
        "going": 64, "approval": False, "tags": ["Tech", "Arts & Culture"],
        "lede": "Shaders, plotters and noise. Bring a laptop and something half finished.",
    },
    {
        "slug": "product-people-mixer", "title": "Product People: autumn mixer", "short": "Product People mixer",
        "rule": {"wd": 2, "week": 1, "h": 17, "m": 30}, "hours": 3,
        "venue": "Studio Norr", "area": "Östermalm, Stockholm", "street": "Riddargatan 31, 114 57 Stockholm",
        "hosts": [["Product People Sthlm", "PP", "#ec4899", "#f97316"]],
        "going": 211, "approval": True, "tags": ["Startups", "Design"],
        "lede": "PMs, designers and engineers, one room, no slides.",
    },
    {
        "slug": "type-tuesdays", "title": "Type Tuesdays: Swedish type from 1900 to now", "short": "Type Tuesdays",
        "rule": {"wd": 1, "week": 2, "h": 18, "m": 0}, "hours": 2,
        "venue": "Bokbinderiet", "area": "Gamla stan, Stockholm", "street": "Köpmangatan 9, 111 31 Stockholm",
        "hosts": [["Typografiska Klubben", "TK", "#b45309", "#78350f"]],
        "going": 39, "approval": False, "tags": ["Design", "Arts & Culture"],
        "lede": "A short history of Swedish letters, told with the books on the table.",
    },
]

BY_SLUG = {e["slug"]: e for e in EVENTS}


def _last_sunday(year, month):
    d = datetime.date(year, month + 1, 1) - datetime.timedelta(days=1) if month < 12 else datetime.date(year, 12, 31)
    return d - datetime.timedelta(days=(d.weekday() + 1) % 7)


def summer(day):
    """Whether Stockholm keeps summer time on this day (EU rules)."""
    return _last_sunday(day.year, 3) <= day < _last_sunday(day.year, 10)


def stockholm_now():
    """The events are in Stockholm, so their days and hours are Stockholm's,
    whatever clock the computer showing them keeps."""
    utc = datetime.datetime.utcnow()
    hours = 2 if summer(utc.date()) else 1
    return utc + datetime.timedelta(hours=hours)


def occurrence(rule, now=None):
    now = now or stockholm_now()
    today = now.date()
    if rule["week"] == 0:
        delta = (rule["wd"] - today.weekday()) % 7 or 7
        d = today + datetime.timedelta(days=delta)
    else:
        monday = today - datetime.timedelta(days=today.weekday()) + datetime.timedelta(weeks=rule["week"])
        d = monday + datetime.timedelta(days=rule["wd"])
    return datetime.datetime(d.year, d.month, d.day, rule["h"], rule["m"])


def starts(event, now=None):
    return occurrence(event["rule"], now)


def ends(event, now=None):
    return starts(event, now) + datetime.timedelta(hours=event["hours"])


def zone(day=None):
    day = day or stockholm_now().date()
    return "GMT+2" if summer(day) else "GMT+1"


def fmt(d, kind):
    if kind == "long":
        return "%s, %s %d" % (d.strftime("%A"), d.strftime("%B"), d.day)
    if kind == "short":
        return "%s, %s %d" % (d.strftime("%a"), d.strftime("%b"), d.day)
    if kind == "md":
        return "%s %d" % (d.strftime("%b"), d.day)
    if kind == "month":
        return d.strftime("%b").upper()
    if kind == "day":
        return str(d.day)
    if kind == "weekday":
        return d.strftime("%A")
    if kind == "time":
        return d.strftime("%H:%M")
    return d.isoformat()


def for_script():
    return {"events": {e["slug"]: {"rule": e["rule"], "hours": e["hours"]} for e in EVENTS}}
