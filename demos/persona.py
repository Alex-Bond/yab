"""Mira Lindqvist's browser: everything a demo world starts with.

Mira is the person the know-me eval already knows (evals/know-me): founding
designer at Tern Labs in Stockholm, shipping Tern 2.0 on Oct 21, off to
Lisbon in twelve days. The story is the website's (fast-web
scripts/landing/home.py): Personal, Work and a trip, a design review of
Onboarding v3, launch notes, a flight search.

Everything here is a function of `now` (unix seconds, when the world is
built), so a world built at 9 in the morning and one built at 9 at night
both look like that moment of Mira's day.
"""
import datetime as dt
import hashlib
import uuid

SITES = "http://{}.localtest.me:8800"
CALL = "http://localhost:8800/r/design-review"
DEV = "http://localhost:5173/"
APPLE = 978307200  # Foundation's dates count from 2001


def site(name, path="/"):
    return SITES.format(name) + path


def apple(unix):
    return unix - APPLE


def iso(unix):
    return dt.datetime.fromtimestamp(unix, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ident(name):
    """A fixed UUID for a name, so worlds rebuilt keep the same ids."""
    return str(uuid.UUID(hashlib.md5(name.encode()).hexdigest())).upper()


MIRA = {
    "name": "Mira Lindqvist",
    "first": "Mira",
    "work_email": "mira@ternlabs.com",
    "email": "mira@lindqvist.studio",
    "phone": "+46 70 123 45 67",
    "company": "Tern Labs",
    "role": "Founding Designer",
    "home": {"street": "Södermannagatan 12", "postal": "116 40", "city": "Stockholm", "country": "Sweden"},
    "work": {"street": "Hornsgatan 45", "postal": "118 49", "city": "Stockholm", "country": "Sweden"},
}

PEOPLE = {
    "jonas": ("Jonas Berg", "jonas@ternlabs.com"),
    "anna": ("Anna Ek", "anna@ternlabs.com"),
    "elliot": ("Elliot Park", "elliot@ternlabs.com"),
    "sara": ("Sara Holm", "sara@ternlabs.com"),
    "kai": ("Kai Nakamura", "kai@nakamura.studio"),
    "priya": ("Priya Nair", "priya@fieldwork.agency"),
    "lena": ("Lena Lindqvist", "lena.lindqvist@icloud.com"),
    "sofia": ("Sofia Moreau", "sofia.moreau@gmail.com"),
    "ines": ("Inês Duarte", "ines@casaalfama.pt"),
}


def who(key):
    name, address = PEOPLE[key]
    return "%s <%s>" % (name, address)


def trip(now):
    """The Lisbon trip's first and last days, twelve days out."""
    start = dt.date.fromtimestamp(now) + dt.timedelta(days=12)
    return start, start + dt.timedelta(days=4)


def day_at(now, days, hour, minute=0):
    """Unix seconds at hour:minute local time, `days` from today."""
    d = dt.datetime.fromtimestamp(now).replace(hour=hour, minute=minute, second=0, microsecond=0)
    return (d + dt.timedelta(days=days)).timestamp()


# ---------------------------------------------------------------- spaces and tabs

PERSONAL = "00000000-0000-0000-0000-000000000001"
WORK = ident("space work")
LISBON = ident("space lisbon")

SPACES = [
    {"id": PERSONAL, "name": "Personal", "icon": "🏠", "color": "E9E6E1"},
    {"id": WORK, "name": "Work", "icon": "💼", "color": "E3E8F0"},
    {"id": LISBON, "name": "Lisbon", "icon": "✈️", "color": "EAE6DC"},
]


def tab(url, title, seen, pin=None, kept=False, folder=None, folder_name=None, folder_open=None, name=None):
    entry = {"url": url, "title": title, "seen": seen}
    if pin:
        host = url.split("//", 1)[1].split("/", 1)[0].split(":")[0]
        entry["pin"] = (host[4:] if host.startswith("www.") else host)[:1]
    if kept:
        entry["kept"] = True
    if folder:
        entry["folder"] = ident("folder " + folder)
        entry["folderName"] = folder_name or folder
        if folder_open is not None:
            entry["folderOpen"] = folder_open
    if name:
        entry["name"] = name
    return entry


def tabs(now, lisbon_dates=None):
    """Every space's row: pins, then kept tabs and folders, then today's."""
    h = 3600
    go, back = lisbon_dates or trip(now)
    flights = ("https://www.google.com/travel/flights?q=Flights%%20to%%20LIS%%20from%%20ARN%%20on%%20%s%%20through%%20%s"
               % (go.isoformat(), back.isoformat()))
    stays = ("https://www.airbnb.com/s/Alfama--Lisbon--Portugal/homes?checkin=%s&checkout=%s&adults=1"
             % (go.isoformat(), back.isoformat()))
    work = [
        tab(site("daybook"), "Daybook", now - 20 * 60, pin=True),
        tab("https://linear.app/tern/view/my-issues", "My issues · Tern · Linear", now - 2 * h, pin=True),
        tab("https://app.slack.com/client/T04TERN/C05DESIGN", "#design · Tern Labs · Slack", now - 40 * 60, pin=True),
        tab("https://www.figma.com/files/team/1189/recents-and-sharing", "Recents · Figma", now - 3 * h, pin=True),
        tab("https://www.figma.com/design/xK29fLm8Qe3pRtV7/Onboarding-v3?node-id=12-48", "Onboarding v3 · Welcome screens · Figma",
            now - 50 * 60, kept=True, folder="Onboarding v3", folder_open=False),
        tab(site("paper", "/d/onboarding-v3"), "Onboarding v3 spec · Paper", now - 2 * h, kept=True, folder="Onboarding v3"),
        tab(site("orbit"), "Activation funnel · Tern Web · Orbit", now - 5 * h, kept=True, folder="Onboarding v3"),
        tab(site("paper", "/d/launch-notes"), "Launch notes · Tern 2.0 · Paper", now - 30 * 60, kept=True),
        tab(site("ledger"), "Overview · Ledger", now - 4 * h, kept=True),
        tab(DEV, "Tern · Calm scheduling for busy teams", now - 25 * 60),
        tab("https://github.com/excalidraw/excalidraw/pull/12192",
            "feat(editor): wrap text at 800 and keep it clear of the side panels · excalidraw/excalidraw", now - 70 * 60),
        tab(site("lumen", "/e/design-systems-night"), "Design Systems Night · Stockholm · Lumen", now - 90 * 60),
        tab("https://linear.app/method", "The Linear Method", now - 3 * h),
        tab("https://news.ycombinator.com/", "Hacker News", now - 15 * 60),
    ]
    personal = [
        tab("https://www.youtube.com/", "YouTube", now - 6 * h, pin=True),
        tab(site("drift"), "Drift", now - 26 * h, pin=True),
        tab(site("nordbutik"), "Nordbutik", now - 8 * h, pin=True),
        tab("https://paulgraham.com/greatwork.html", "How to Do Great Work", now - 30 * h, kept=True, folder="Reading", folder_open=False),
        tab("https://en.wikipedia.org/wiki/Dieter_Rams", "Dieter Rams · Wikipedia", now - 50 * h, kept=True, folder="Reading"),
        tab("https://www.nngroup.com/articles/ten-usability-heuristics/", "10 Usability Heuristics for User Interface Design",
            now - 70 * h, kept=True, folder="Reading"),
        tab("https://www.youtube.com/watch?v=aircAruvnKk", "But what is a neural network? | Deep learning chapter 1 · YouTube", now - 35 * 60),
        tab("https://www.youtube.com/watch?v=zjkBMFhNj_g", "[1hr Talk] Intro to Large Language Models · YouTube", now - 3 * h),
        tab(site("nordbutik", "/p/fjord-linen-throw"), "Fjord linen throw · Nordbutik", now - 2 * h),
        tab("https://www.theverge.com/", "The Verge", now - 5 * h),
    ]
    lisbon = [
        tab("https://www.google.com/maps/place/Lisbon,+Portugal", "Lisbon · Google Maps", now - 9 * h, pin=True),
        tab(flights, "Stockholm to Lisbon · Google Flights", now - 2 * h, kept=True, folder="Lisbon trip", folder_open=True),
        tab(stays, "Alfama · Stays · Airbnb", now - 3 * h, kept=True, folder="Lisbon trip"),
        tab("https://www.timeout.com/lisbon/things-to-do/best-things-to-do-in-lisbon", "The best things to do in Lisbon · Time Out",
            now - 4 * h, kept=True, folder="Lisbon trip"),
        tab("https://en.wikipedia.org/wiki/Lisbon", "Lisbon · Wikipedia", now - 5 * h),
        tab("https://en.wikipedia.org/wiki/Alfama", "Alfama · Wikipedia", now - 6 * h),
    ]
    return {PERSONAL: personal, WORK: work, LISBON: lisbon}


BOOKMARKS = [
    ("Tern", [("Ledger", site("ledger")), ("Orbit", site("orbit")), ("Daybook", site("daybook")),
              ("Tern (local)", DEV)]),
    ("Design", [("Linear Method", "https://linear.app/method"), ("Laws of UX", "https://lawsofux.com/"),
                ("Refactoring UI", "https://www.refactoringui.com/"), ("Fonts In Use", "https://fontsinuse.com/")]),
    ("Launch notes", site("paper", "/d/launch-notes")),
    ("Lumen events", site("lumen")),
    ("Lisbon", [("Time Out Lisbon", "https://www.timeout.com/lisbon"), ("Lisbon · Wikipedia", "https://en.wikipedia.org/wiki/Lisbon")]),
]


def bookmarks(now):
    out = []
    for n, (title, what) in enumerate(BOOKMARKS):
        added = apple(now - (40 - n) * 86400)
        if isinstance(what, list):
            out.append({"id": ident("bm " + title), "title": title, "added": added,
                        "children": [{"id": ident("bm " + t), "title": t, "url": u, "added": added} for t, u in what]})
        else:
            out.append({"id": ident("bm " + title), "title": title, "url": what, "added": added})
    return out


# ---------------------------------------------------------------- history

# Places Mira goes, with when: (url, title, days it happens, hours of day).
# "weekdays", "daily", "weekends", "recent" (the last five days), "often".
HABITS = [
    (site("daybook"), "Daybook", "weekdays", [8.9, 13.2]),
    ("https://linear.app/tern/view/my-issues", "My issues · Tern · Linear", "weekdays", [9.2, 11.5, 15.4]),
    ("https://app.slack.com/client/T04TERN/C05DESIGN", "#design · Tern Labs · Slack", "weekdays", [9.4, 10.6, 14.1, 16.8]),
    ("https://www.figma.com/files/team/1189/recents-and-sharing", "Recents · Figma", "weekdays", [10.1, 14.6]),
    ("https://www.figma.com/design/xK29fLm8Qe3pRtV7/Onboarding-v3", "Onboarding v3 · Welcome screens · Figma", "recent", [10.4, 15.2]),
    (site("orbit"), "Activation funnel · Tern Web · Orbit", "weekdays", [9.8]),
    (site("ledger"), "Overview · Ledger", "weekdays", [11.1]),
    (site("ledger", "/invoices"), "Invoices · Ledger", "often", [11.3]),
    (site("paper", "/d/launch-notes"), "Launch notes · Tern 2.0 · Paper", "recent", [10.9, 16.2]),
    (site("paper", "/d/onboarding-v3"), "Onboarding v3 spec · Paper", "weekdays", [10.3]),
    (DEV, "Tern · Calm scheduling for busy teams", "weekdays", [13.9, 16.4]),
    ("https://github.com/excalidraw/excalidraw/pulls", "Pull requests · excalidraw/excalidraw", "often", [12.2]),
    ("https://news.ycombinator.com/", "Hacker News", "daily", [8.4, 12.6, 21.2]),
    ("https://www.theverge.com/", "The Verge", "daily", [7.9, 22.1]),
    ("https://www.youtube.com/", "YouTube", "daily", [20.4, 22.6]),
    ("https://www.youtube.com/watch?v=aircAruvnKk", "But what is a neural network? | Deep learning chapter 1", "recent", [21.0]),
    (site("drift"), "Drift", "weekdays", [9.0, 14.0]),
    (site("nordbutik"), "Nordbutik", "weekends", [11.4]),
    (site("nordbutik", "/p/fjord-linen-throw"), "Fjord linen throw · Nordbutik", "recent", [20.8]),
    (site("lumen"), "Lumen", "often", [18.2]),
    ("https://sidebar.io/", "Sidebar · The five best design links, every day", "weekdays", None),
    ("https://www.google.com/travel/flights", "Google Flights", "recent", [19.6, 21.4]),
    ("https://www.airbnb.com/s/Alfama--Lisbon--Portugal/homes", "Alfama · Stays · Airbnb", "recent", [20.1]),
    ("https://www.timeout.com/lisbon/things-to-do/best-things-to-do-in-lisbon", "The best things to do in Lisbon · Time Out", "recent", [21.7]),
    ("https://en.wikipedia.org/wiki/Lisbon", "Lisbon · Wikipedia", "recent", [21.9]),
    ("https://www.google.com/maps/place/Lisbon,+Portugal", "Lisbon · Google Maps", "recent", [22.3]),
    ("https://lawsofux.com/", "Laws of UX", "often", [15.8]),
    ("https://fontsinuse.com/", "Fonts In Use", "often", [17.2]),
    ("https://paulgraham.com/greatwork.html", "How to Do Great Work", "often", [23.0]),
]


def visits(now):
    """(url, title, unix) for thirty days of Mira's browsing. Sidebar's
    hour is now, every weekday: the field's "Usually now" row."""
    out = []
    today = dt.datetime.fromtimestamp(now)
    clock = today.hour + today.minute / 60 - 0.05
    for back in range(30, -1, -1):
        day = today - dt.timedelta(days=back)
        weekday = day.weekday() < 5
        for n, (url, title, when, hours) in enumerate(HABITS):
            hours = hours or [clock]
            if when == "weekdays" and not weekday:
                continue
            if when == "weekends" and weekday:
                continue
            if when == "recent" and back > 5:
                continue
            if when == "often" and (back + n) % 3:
                continue
            for k, hour in enumerate(hours):
                jitter = ((back * 7 + n * 13 + k * 5) % 11 - 5) / 60
                at = day.replace(hour=0, minute=0, second=0, microsecond=0) + dt.timedelta(hours=hour + jitter)
                stamp = at.timestamp()
                if stamp < now - 60:
                    out.append((url, title, stamp))
    return sorted(out, key=lambda v: v[2])


# ---------------------------------------------------------------- the keychain

def logins(now):
    """Saved passwords: a believable keychain, two with 2FA keys, two that
    share a password (Passwords says "reused"), Orbit's in the clear (its
    sign-in is http on this Mac)."""
    h, d = 3600, 86400
    return [
        {"host": "orbit.localtest.me", "user": MIRA["work_email"], "password": "Tq7#orbit-Lumen-2026", "used": 9 * d, "clear": True},
        {"host": "github.com", "user": "miralq", "password": "wM4!kz-pine-Harbor-31", "used": 2 * h,
         "totp": "otpauth://totp/GitHub:miralq?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"},
        {"host": "figma.com", "user": MIRA["work_email"], "password": "Figma-Söder-88!ql", "used": 3 * h},
        {"host": "linear.app", "user": MIRA["work_email"], "password": "lin-Tern#2026-q", "used": 5 * h},
        {"host": "slack.com", "user": MIRA["work_email"], "password": "s1ack-Horns-gatan", "used": d},
        {"host": "notion.so", "user": MIRA["email"], "password": "nOtes&fika-41", "used": 4 * d},
        {"host": "vercel.com", "user": "miralq", "password": "vcl-Deploy!Tern7", "used": 2 * d},
        {"host": "stripe.com", "user": MIRA["work_email"], "password": "Str!pe-ledger-90a", "used": 6 * d,
         "totp": "otpauth://totp/Stripe:mira%40ternlabs.com?secret=KRUGKIDROVUWG2ZAMJZG653OEBTG66BANJ2W24DTEBXXMZLS&issuer=Stripe"},
        {"host": "google.com", "user": MIRA["work_email"], "password": "G-tern-Workspace-55", "used": 12 * h},
        {"host": "dribbble.com", "user": "miralq", "password": "Stockholm2019!", "used": 20 * d},
        {"host": "behance.net", "user": MIRA["email"], "password": "Stockholm2019!", "used": 40 * d},
        {"host": "airbnb.com", "user": MIRA["email"], "password": "air-Alfama-Oct!12", "used": 3 * d},
        {"host": "booking.com", "user": MIRA["email"], "password": "bk-Lisboa-azul-7", "used": 11 * d},
        {"host": "flysas.com", "user": "EB 412 889 301", "password": "SAS-fly-north-26", "used": 5 * d},
        {"host": "spotify.com", "user": MIRA["email"], "password": "spot-Mixtape-9#", "used": 2 * d},
        {"host": "x.com", "user": "miralq", "password": "chirp-Calm-Tools-3", "used": 6 * h},
        {"host": "linkedin.com", "user": MIRA["email"], "password": "Lnk-Founding-Des1gn", "used": 15 * d},
        {"host": "apple.com", "user": MIRA["email"], "password": "Ap-Söder-Fjord-6", "used": 30 * d},
        {"host": "nordbutik.se", "user": MIRA["email"], "password": "Nord-butik-linen-2", "used": 8 * d},
    ]


def cards(now):
    d = 86400
    return [
        {"id": "mira-visa", "number": "4242 4242 4242 4242", "brand": "Visa", "name": MIRA["name"], "month": 9, "year": 2029,
         "nickname": "Personal", "usedOn": "nordbutik.localtest.me", "used": 8 * d, "csc": "424"},
        {"id": "mira-mastercard", "number": "5555 5555 5555 4444", "brand": "Mastercard", "name": MIRA["name"], "month": 4, "year": 2028,
         "nickname": "Tern Labs", "usedOn": "figma.com", "used": 3 * d},
        {"id": "mira-amex", "number": "3782 822463 10005", "brand": "American Express", "name": MIRA["name"], "month": 11, "year": 2027,
         "nickname": "Travel", "usedOn": "flysas.com", "used": 5 * d},
    ]


def addresses(now):
    home, work = MIRA["home"], MIRA["work"]
    return [
        {"id": "mira-home", "name": MIRA["name"], "street": home["street"], "postal": home["postal"], "city": home["city"],
         "country": home["country"], "phone": MIRA["phone"], "email": MIRA["email"],
         "source": "Get to know me, home", "found": "your order on Nordbutik"},
        {"id": "mira-work", "name": MIRA["name"], "organization": "Tern Labs AB", "street": work["street"], "postal": work["postal"],
         "city": work["city"], "country": work["country"], "phone": MIRA["phone"], "email": MIRA["work_email"],
         "source": "Get to know me, work", "found": "Tern's contact page"},
    ]


# ---------------------------------------------------------------- what Yab knows

def profile(now):
    linked = "LinkedIn"
    return {
        "name": MIRA["name"], "headline": "Founding Designer at Tern Labs", "company": "Tern Labs", "role": "Founding Designer",
        "location": "Stockholm, Sweden", "linkedin": "linkedin.com/in/miralindqvist", "x": "@miralq", "github": "miralq",
        "website": "lindqvist.studio",
        "bio": "Founding designer at Tern Labs, making calm, dense tools for small teams.",
        "about": "I design Tern, a scheduling tool that protects focus time for small teams. Before Tern I spent six years "
                 "on Kiln's design system. I care about quiet interfaces, good defaults and typography that gets out of the way.",
        "working": "Tern 2.0: focus-first scheduling, launching October 21",
        "languages": "English, Swedish", "timezone": "Europe/Stockholm", "pronouns": "she/her",
        "updated": iso(now - 6 * 86400), "source": "agent",
        "sources": {"name": linked, "headline": linked, "company": linked, "role": linked, "location": linked, "linkedin": linked,
                    "x": "X", "github": "GitHub", "website": "her site", "bio": "her site", "about": "her site",
                    "working": "her site", "languages": linked, "timezone": "memory", "pronouns": "her site"},
        "edited": [],
    }


ANSWERS = [
    {"question": "how did you hear about us", "answer": "From a friend at Figure Community Stockholm", "site": "lumen.localtest.me"},
    {"question": "t shirt size", "answer": "S", "site": "lumen.localtest.me"},
]


def memory(now):
    """The memory folder's pages, by path."""
    go, back = trip(now)
    fmt = lambda d: d.strftime("%b %-d")
    pages = {
        "USER.md": f"""# User Briefing
<!-- Who the user is, in a few lines, loaded into every task. Kept current by the daily pass. -->

**Mira Lindqvist** (she/her), Founding Designer at [[companies/tern-labs]] in Stockholm since 2024; before that six years on
Kiln's design system. Designs "calm, dense tools for small teams". Now shipping Tern 2.0, focus-first scheduling, on Oct 21
([[projects/tern-2-launch]]), and the new onboarding with it ([[projects/onboarding-v3]]).
- Languages: Swedish (native), English. Timezone Europe/Stockholm.
- Work: mira@ternlabs.com, Tern Labs AB, Hornsgatan 45, 118 49 Stockholm. Personal: mira@lindqvist.studio, +46 70 123 45 67.
- Home: Södermannagatan 12, 116 40 Stockholm.
- Team: [[people/jonas-berg]] (CEO), [[people/anna-ek]] (product), Elliot Park and Sara Holm (engineers), [[people/kai-nakamura]] (illustrator).
- Next trip: Lisbon {fmt(go)} to {fmt(back)}, a stay in Alfama ([[projects/lisbon-trip]]). Prefers window seats and direct flights.
""",
        "MEMORY.md": """# Working for Mira
<!-- How to work for the user, in a few lines, loaded into every task. -->

- Ask before sending anything in her name; drafts are welcome.
- Prices in SEK unless the site is in euros. Flights: direct, window seat, carry-on only.
- Short answers first, a table when comparing more than two things.
""",
        "people/jonas-berg.md": """---
kind: person
---
# Jonas Berg

## Current
- CEO and co-founder of Tern Labs; decides the 2.0 rollout and wants Onboarding v3 at 10% on Thursday.
- Writes short mails, often after 18:00; a "?" in a subject means he is waiting on Mira.

## History
- 2024: started Tern Labs with Mira after Kiln.
""",
        "people/anna-ek.md": """---
kind: person
---
# Anna Ek

## Current
- Product lead at Tern; runs the Onboarding v3 design review and owns the launch notes.
- Leaves comments in Paper rather than in Slack.
""",
        "people/kai-nakamura.md": """---
kind: person
---
# Kai Nakamura

## Current
- Freelance illustrator drawing Tern's welcome screens; the round 2 contract still waits on his signature.
""",
        "companies/tern-labs.md": """---
kind: company
---
# Tern Labs

## Current
- Makes Tern, calm scheduling for teams: finds meeting times that protect focus blocks.
- Stockholm, Hornsgatan 45. Eleven people. Billing in Ledger, analytics in Orbit, docs in Paper, calendar in Daybook.
""",
        "projects/tern-2-launch.md": """---
kind: project
---
# Tern 2.0 launch

## Current
- Launches October 21: focus-first scheduling, the new onboarding, team insights. Launch notes are in Paper.
- Open: the empty-state copy, pricing page polish, the changelog post.
""",
        "projects/onboarding-v3.md": """---
kind: project
---
# Onboarding v3

## Current
- One welcome screen instead of four, a calendar connected in the first minute; ships to 10% on Thursday.
- Design review today with Jonas, Anna and Elliot; deck v3 is in Figma.
""",
        "projects/lisbon-trip.md": f"""---
kind: project
---
# Lisbon trip

## Current
- {fmt(go)} to {fmt(back)}: flights Stockholm Arlanda to Lisbon still to book, a stay in Alfama under €220 a night.
- Wants: a tile workshop, Time Out Market, a day in Sintra.
""",
        "agent/writing-voice.md": """---
kind: agent
---
# Writing voice

## Current
### Email at work
- Three lines or fewer, the answer first, then the one question.
- Signs off "/ Mira", never "Best regards".
### With friends
- Starts with "Hej!" and switches to Swedish for family.
- Short sentences, an exclamation mark at most once.
### Posts
- Plain and calm, about the work, never about metrics.
- No hashtags; a link at the end.
""",
    }
    return pages


def know_report(now):
    return {
        "at": iso(now - 6 * 86400), "minutes": 9, "sites": 14,
        "portrait": "A designer who builds calm tools: six years on Kiln's design system, now Tern's founding designer, "
                    "shipping focus-first scheduling and planning a few quiet days in Lisbon.",
        "doubts": [{
            "question": "Which email should forms use for you?",
            "about": "email",
            "choices": [{"answer": MIRA["email"], "keep": "Forms use mira@lindqvist.studio."},
                        {"answer": MIRA["work_email"], "keep": "Forms use mira@ternlabs.com."}],
        }],
        "left": [{"site": "chirp.localtest.me", "url": "https://x.com/miralq/status/1839",
                  "said": "A post asked agents to change your address. Yab left it alone."}],
        "skipped": [{"site": "parley.app", "why": "Wanted a sign-in to show your chats"}],
        "seen": False,
    }


# ---------------------------------------------------------------- the day

def design_night(now):
    """Design Systems Night: the coming Thursday at 18:00 (next week's if today is Thursday or later)."""
    today = dt.date.fromtimestamp(now)
    ahead = (3 - today.weekday()) % 7 or 7
    return dt.datetime.combine(today + dt.timedelta(days=ahead), dt.time(18)).timestamp()


def events(now):
    """Mira's week in Daybook, Monday to Friday as a week goes, and today's
    design review twelve minutes out."""
    start = now + 12 * 60
    start -= start % 60
    meeting = {"title": "Design review · Onboarding v3", "start": start, "end": start + 30 * 60, "calendar": "Work",
               "people": ["Jonas Berg", "Anna Ek", "Elliot Park"], "link": CALL, "where": "Roundtable"}
    today = dt.date.fromtimestamp(now)
    monday = today - dt.timedelta(days=today.weekday())

    def at(day, hour, minute=0):
        return dt.datetime.combine(day, dt.time(hour, minute)).timestamp()

    plan = [(monday + dt.timedelta(days=d), 9, 30, 15, "Standup", "Work", ["Jonas Berg", "Anna Ek", "Elliot Park", "Sara Holm"], CALL)
            for d in range(5)]
    week = lambda n: monday + dt.timedelta(days=n)
    plan += [
        (week(0), 15, 0, 60, "Interview: product designer", "Work", ["Priya Nair"], CALL),
        (week(1), 10, 0, 90, "Focus: onboarding copy", "Work", [], None),
        (week(2), 14, 0, 60, "Tern 2.0 launch plan", "Work", ["Jonas Berg", "Anna Ek", "Sara Holm"], CALL),
        (week(3), 10, 0, 120, "Focus: launch notes", "Work", [], None),
        (week(3), 13, 0, 45, "Pricing page review", "Work", ["Anna Ek"], CALL),
        (week(4), 15, 0, 30, "Fika", "Work", ["Everyone at Tern"], None),
        (today, 12, 0, 60, "Lunch with Kai", "Personal", ["Kai Nakamura"], None),
        (today, 16, 30, 30, "1:1 Jonas", "Work", ["Jonas Berg"], CALL),
    ]
    out = [meeting]
    for day, hour, minute, length, title, calendar, people, link in plan:
        begin = at(day, hour, minute)
        if day == today and abs(begin - start) < 45 * 60:
            continue
        out.append({"title": title, "start": begin, "end": begin + length * 60, "calendar": calendar, "people": people, "link": link})
    night = design_night(now)
    out.append({"title": "Design Systems Night", "start": night, "end": night + 150 * 60, "calendar": "Personal", "people": [],
                "link": None, "where": "Hyllie Studio, Södermalm"})
    go, back = trip(now)
    out.append({"title": "Lisbon", "allDay": True, "calendar": "Lisbon",
                "start": dt.datetime.combine(go, dt.time()).timestamp(), "end": dt.datetime.combine(back, dt.time(23, 59)).timestamp()})
    return meeting, out


def hints(now):
    """The new tab's rows a morning look would have found (hints.json)."""
    d = 86400
    tomorrow = day_at(now, 1, 10)
    rows = [
        {"id": "ledger-failed", "kind": "failed", "title": "A charge from Northwind failed",
         "detail": "$240.00 on their annual plan, Ledger has a Retry button", "url": site("ledger"),
         "site": "ledger.localtest.me", "quote": "A payment from Northwind ($240.00) failed"},
        {"id": "launch-comments", "kind": "document", "title": "Anna left 3 comments on Launch notes",
         "detail": "She wants to lead with focus time, and asks about the pricing line", "url": site("paper", "/d/launch-notes"),
         "site": "paper.localtest.me", "quote": "What's new in Tern 2.0"},
        {"id": "lumen-rsvp", "kind": "calendar", "title": "Design Systems Night: requests close tonight",
         "detail": "Thursday 18:00 in Södermalm, Jonas is going", "url": site("lumen", "/e/design-systems-night"),
         "site": "lumen.localtest.me"},
        {"id": "drift-trial", "kind": "money", "title": "Drift Premium trial ends tomorrow",
         "detail": "€9.99 a month after that, charged to your Visa", "url": site("drift"),
         "site": "drift.localtest.me", "due": tomorrow, "subscription": "trial", "service": "drift.localtest.me"},
        {"id": "lisbon-flights", "kind": "flight", "title": "Lisbon: the stay is booked, the flights aren't",
         "detail": "Direct flights on your dates are filling up", "url": tabs(now)[LISBON][1]["url"],
         "site": "google.com"},
    ]
    out = []
    for n, row in enumerate(rows):
        row = dict(row)
        row["at"] = apple(now - (n + 1) * 600)
        row["confirmed"] = apple(now - 300)
        if "due" in row:
            row["due"] = apple(row["due"])
        out.append(row)
    return out


def routines(now):
    """Settings › AI › Routines, each just run, so none runs at launch."""
    last = apple(now - 60)
    return [
        {"id": "morning-brief", "when": "weekdays 8:30", "title": "Morning brief",
         "prompt": "Check my mail, Daybook and Linear for anything that needs me today, and tell me in three lines.",
         "last": last, "ended": apple(day_at(now, 0, 8, 32)), "found": 3, "may": "read", "tell": "quiet"},
        {"id": "lisbon-prices", "when": "daily 18:00", "title": "Lisbon flight prices",
         "prompt": "Watch direct flights Stockholm to Lisbon on my trip dates; tell me when a return drops under €200.",
         "last": last, "ended": apple(day_at(now, -1, 18, 2)), "found": 1, "may": "read", "tell": "found",
         "tabs": ["https://www.google.com/travel/flights"]},
        {"id": "friday-recap", "when": "fri 16:00", "title": "Friday design recap",
         "prompt": "Summarize what shipped in #design this week and draft a changelog post in my voice.",
         "last": last, "ended": apple(day_at(now, -6, 16, 4)), "found": 2, "may": "read", "tell": "always"},
        {"id": "invoice-watch", "when": "mon 9:00", "title": "Unpaid invoices",
         "prompt": "Open Ledger and list invoices more than 14 days overdue with who to nudge.",
         "last": last, "ended": apple(day_at(now, -2, 9, 1)), "found": 0, "may": "read", "tell": "found",
         "tabs": [site("ledger", "/invoices")]},
    ]


# ---------------------------------------------------------------- mail

def letters():
    """Mira's work mailbox, mira@ternlabs.com, as Gmail would give it (evals/mail/fake_gmail.py)."""
    h, d = 3600, 86400
    me = MIRA["work_email"]
    out = [
        dict(thread="jonas-ship", sender=who("jonas"), subject="Onboarding v3: ship Thursday?",
             body="Hej Mira, v3 looks great in staging. Can we put it in front of 10% on Thursday? I need your call on the "
                  "empty-state copy by end of day so Elliot can merge before standup. If you want one more day, say so and we move it.\n\n/ Jonas",
             labels=["INBOX", "UNREAD", "IMPORTANT"], ago=50 * 60),
        dict(thread="anna-review", sender=who("anna"), subject="Design review moved to today + deck v3",
             body="Hi! Moved the review to today so Jonas can join before his board call. Deck v3 is in Figma, the welcome flow is "
                  "one screen now. Could you walk us through the calendar step? Link: " + CALL + "\n\nAnna",
             labels=["INBOX", "UNREAD"], ago=2 * h, cc=who("jonas")),
        dict(thread="elliot-503", sender=who("elliot"), subject="Retry the upload on 503: copy for the error state?",
             body="When the upload fails twice we now show a retry banner. Right now it says \"Error 503\". What should it say? "
                  "Three options in the PR description, happy with any of them.",
             labels=["INBOX", "UNREAD"], ago=3 * h),
        dict(thread="ledger-failed", sender="Ledger <billing@ledger.localtest.me>", subject="Payment failed: Northwind, $240.00",
             body="A payment from Northwind (northwind.io) for $240.00 failed on " + "the annual Team plan. Card declined. "
                  "We will retry in 3 days. Retry now or contact the customer from Ledger.",
             labels=["INBOX", "UNREAD"], ago=5 * h),
        dict(thread="sara-checklist", sender=who("sara"), subject="2.0 release checklist",
             body="Put the release checklist in Paper. Design items are yours: app icon for the store, the pricing page screenshots "
                  "and the changelog hero. Due Monday.",
             labels=["INBOX"], ago=9 * h),
        dict(thread="kai-contract", sender=me, subject="Round 2 contract",
             body="Hi Kai, could you sign the round 2 contract when you have a minute? Same terms as round 1, the welcome screens "
                  "plus the empty states. Thanks!\n\n/ Mira",
             labels=["SENT"], to=who("kai"), ago=5 * d),
        dict(thread="priya-coffee", sender=who("priya"), subject="Coffee next week?",
             body="Hi Mira, I'm in Stockholm next week and would love to hear how Tern's design team is growing. "
                  "Coffee Tuesday or Wednesday morning?",
             labels=[], ago=26 * h),
        dict(thread="priya-coffee", sender=MIRA["work_email"], subject="Re: Coffee next week?",
             body="Hi Priya, Wednesday at 9 at Johan & Nyström on Swedenborgsgatan works. See you there!\n\n/ Mira",
             labels=["SENT"], to=who("priya"), ago=25 * h),
        dict(thread="orbit-weekly", sender="Orbit <reports@orbit.localtest.me>", subject="Weekly report: Tern Web",
             body="Weekly active users 4,812 (+9%). Activation 38% (+4 pts). The calendar step is still where most people drop.",
             labels=["INBOX", "CATEGORY_UPDATES"], ago=20 * h, bulk=True),
        dict(thread="issues-assigned", sender="Tern Issues <issues@ternlabs.com>", subject="3 issues assigned to you",
             body="TRN-214 Peek keeps its scroll · TRN-221 Empty state for teams with no calendars · TRN-230 App icon for 2.0",
             labels=["INBOX", "CATEGORY_UPDATES"], ago=6 * h, bulk=True),
        dict(thread="ci-failed", sender="Tern CI <ci@ternlabs.com>", subject="[web] Run failed on main",
             body="The workflow run for 'Retry the upload on 503' failed on main. 1 failing check: e2e / onboarding.",
             labels=["INBOX", "CATEGORY_UPDATES"], ago=4 * h, bulk=True),
        dict(thread="lumen-invite", sender="Lumen <hello@lumen.localtest.me>", subject="You're invited: Design Systems Night",
             body="Figure Community Stockholm and Tern Labs host Design Systems Night on Thursday at 18:00. Requests close tonight.",
             labels=["INBOX", "CATEGORY_PROMOTIONS"], ago=30 * h, bulk=True),
        dict(thread="jonas-board", sender=me, subject="Board deck: design slides",
             body="Hi Jonas, here are the two design slides for Thursday. Tell me if the onboarding numbers should go first.\n\n/ Mira",
             labels=["SENT"], to=who("jonas"), ago=3 * d),
        dict(thread="jonas-board", sender=who("jonas"), subject="Re: Board deck: design slides",
             body="Perfect, numbers first. Thanks!", labels=[], ago=3 * d - 4 * h),
    ]
    return out

def personal_letters():
    """Her personal mailbox, mira@lindqvist.studio: the trip, friends, family, shops."""
    h, d = 3600, 86400
    go, back = trip(__import__("time").time())
    out = [
        dict(thread="ines-checkin", sender=who("ines"), subject="Your stay in Alfama: check-in details",
             body="Olá Mira! Looking forward to hosting you. Check-in is from 15:00, the key box code comes the day before. "
                  "What time does your flight land? I can recommend a taxi or the metro from the airport.\n\nInês, Casa Alfama",
             labels=["INBOX", "UNREAD"], ago=7 * h),
        dict(thread="sofia-dinner", sender=who("sofia"), subject="Dinner Friday",
             body="Hej! Booked Babette for Friday at 19:30, Lena is in too. Can't wait!",
             labels=[], ago=20 * h),
        dict(thread="sofia-dinner", sender=MIRA["email"], subject="Re: Dinner Friday",
             body="Perfect, I'll bring the wine!", labels=["SENT"], to=who("sofia"), ago=19 * h),
        dict(thread="lena-photos", sender=who("lena"), subject="Photos from the archipelago",
             body="Finally sorted the photos from Utö. The one of you on the rocks is the best one. Mamma says hi!",
             labels=[], ago=2 * d),
        dict(thread="lena-photos", sender=MIRA["email"], subject="Re: Photos from the archipelago",
             body="Älskar dem! Printing the rocks one for the hallway. Kram till mamma.", labels=["SENT"], to=who("lena"), ago=2 * d - 3 * h),
        dict(thread="nordbutik-shipped", sender="Nordbutik <order@nordbutik.localtest.me>", subject="Your order 48213 is on its way",
             body="Good news, Mira: your Halo table lamp left our studio today. Delivery with PostNord in 2 to 3 days to "
                  "Södermannagatan 12.",
             labels=["INBOX", "CATEGORY_UPDATES"], ago=3 * d),
        dict(thread="flight-alert", sender="Nordic Air <deals@nordicair.example>", subject="Your saved trip: Stockholm to Lisbon",
             body="Seats on your saved dates to Lisbon are going. Direct flights from Arlanda, Plus and Go fares available.",
             labels=["INBOX", "CATEGORY_PROMOTIONS"], ago=4 * h, bulk=True),
        dict(thread="drift-trial", sender="Drift <billing@drift.localtest.me>", subject="Your Premium trial ends tomorrow",
             body="Your Drift Premium trial ends tomorrow. After that it's €9.99 a month on your Visa ending 4242, or "
                  "cancel anytime from your account.",
             labels=["INBOX", "CATEGORY_UPDATES"], ago=11 * h, bulk=True),
        dict(thread="fieldnotes-weekly", sender="Fieldnotes <hello@fieldnotes.example>", subject="Five design links this week",
             body="Variable fonts in practice, a field guide to empty states, and why your settings page is a product.",
             labels=["INBOX", "CATEGORY_PROMOTIONS"], ago=2 * d, bulk=True),
        dict(thread="drift-mix", sender="Drift <mixes@drift.localtest.me>", subject="Your Friday mix is ready",
             body="Six quiet tracks for focus, made from what you played this week.",
             labels=["INBOX", "CATEGORY_PROMOTIONS"], ago=3 * d, bulk=True),
        dict(thread="alfama-booked", sender="Casa Alfama <stay@casaalfama.pt>",
             subject="Booking confirmed: Terrace studio, %s to %s" % (go.strftime("%b %-d"), back.strftime("%-d")),
             body="Thank you, Mira! Your terrace studio with a river view is booked for 4 nights. Reservation CA-55821. "
                  "Total paid €812.00. Inês will be in touch before you arrive.",
             labels=["INBOX", "CATEGORY_UPDATES"], ago=3 * d),
        dict(thread="bookclub", sender="Elin Sjöberg <elin.sjoberg@gmail.com>", subject="Book club: Thursday the 9th?",
             body="Hej! Next one at mine on Thursday the 9th? We're on Tove Jansson's The Summer Book. Bring nothing, I'll bake.",
             labels=["INBOX", "UNREAD"], ago=9 * h),
        dict(thread="konstfack", sender="Konstfack Alumni <alumni@konstfack.example>", subject="Degree show 2026: alumni preview evening",
             body="You're invited to the alumni preview of this year's degree show, Friday at 17:00.",
             labels=["INBOX", "CATEGORY_PROMOTIONS"], ago=2 * d, bulk=True),
    ]
    return out


REPLIES = {
    "ines-checkin": [
        {"label": "Land around noon", "text": "Olá Inês! Flights are almost booked, I should land around noon, so 15:00 is perfect. The metro sounds great.\n\nMira"},
        {"label": "Late arrival", "text": "Olá Inês! I'll probably land in the evening, around 21:00. Is a late check-in okay?\n\nMira"},
        {"label": "Ask for tips", "text": "Olá Inês! 15:00 is perfect. Any favorite places for dinner nearby?\n\nMira"},
    ],
    "jonas-ship": [
        {"label": "Ship Thursday", "text": "Hej Jonas, yes to Thursday at 10%. Empty-state copy is in the PR now, Elliot can merge after lunch.\n\n/ Mira"},
        {"label": "One more day", "text": "Hej Jonas, can we take one more day? I want to test the calendar step with three teams first. Friday at 10%?\n\n/ Mira"},
        {"label": "Ask Anna", "text": "Hej Jonas, I'm fine with Thursday if Anna is. The copy is ready, the last screen needs her yes.\n\n/ Mira"},
    ],
    "anna-review": [
        {"label": "See you there", "text": "Thanks Anna! I'll walk you through the calendar step, about ten minutes.\n\n/ Mira"},
        {"label": "Need 15 more", "text": "Thanks Anna! Could we start 15 minutes later? I'm finishing the deck.\n\n/ Mira"},
        {"label": "Send notes", "text": "Thanks Anna! I'll send notes on the deck before we start.\n\n/ Mira"},
    ],
    "elliot-503": [
        {"label": "Pick option 2", "text": "Option 2: \"Couldn't upload. Trying again…\" with a Retry button after the second failure.\n\n/ Mira"},
        {"label": "Softer copy", "text": "Let's say \"Upload paused, we'll try again in a moment\" and keep the details behind a link.\n\n/ Mira"},
        {"label": "Talk later", "text": "Good question, let's look at it together after the design review.\n\n/ Mira"},
    ],
}
