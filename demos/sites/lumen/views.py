"""Lumen's pages, written on the server so an agent reads them whole; the
page's script only keeps the dates and the clock current."""
import json
from html import escape

events = None  # set by routes.py


def h(s):
    return escape(str(s), quote=True)


ICONS = {
    "pin": '<path d="M12 21s-6.5-6.2-6.5-11a6.5 6.5 0 0 1 13 0c0 4.8-6.5 11-6.5 11z"/><circle cx="12" cy="10" r="2.3"/>',
    "out": '<path d="M9 6h9v9M18 6L6 18"/>',
    "back": '<path d="M15 6l-6 6 6 6"/>',
    "check": '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    "person": '<circle cx="12" cy="8.5" r="3.6"/><path d="M5 20c1.1-3.4 3.8-5.2 7-5.2s5.9 1.8 7 5.2"/>',
    "approve": '<circle cx="10" cy="8.5" r="3.6"/><path d="M3.5 20c1-3.2 3.5-5 6.5-5 1.2 0 2.3.3 3.3.8"/><path d="M15 18l2 2 4-4.5"/>',
    "calendar": '<rect x="4" y="5.5" width="16" height="14.5" rx="3"/><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4"/>',
    "mail": '<rect x="3.5" y="5.5" width="17" height="13" rx="2.5"/><path d="M4 7l8 6 8-6"/>',
    "flag": '<path d="M6 21V4.5M6 5h11l-2 4 2 4H6"/>',
    "share": '<path d="M12 15V4M8 8l4-4 4 4"/><path d="M5 12v6.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V12"/>',
    "ticket": '<path d="M4 8.5V6.5A1.5 1.5 0 0 1 5.5 5h13A1.5 1.5 0 0 1 20 6.5v2a2.5 2.5 0 0 0 0 5v2a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 15.5v-2a2.5 2.5 0 0 0 0-5z"/><path d="M14 5v12" stroke-dasharray="2 2.5"/>',
    "compass": '<circle cx="12" cy="12" r="8.5"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>',
    "search": '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
    "sparkle": '<path d="M12 3.5l1.6 4.9 4.9 1.6-4.9 1.6L12 16.5l-1.6-4.9L5.5 10l4.9-1.6z"/>',
    "edit": '<path d="M5 19h4L19 9l-4-4L5 15z"/>',
    "users": '<circle cx="9" cy="9" r="3.3"/><path d="M3.5 19c.9-3 3-4.6 5.5-4.6s4.6 1.6 5.5 4.6"/><circle cx="16.5" cy="8" r="2.6"/><path d="M15.5 13.6c2.4-.3 4.3 1.1 5 3.9"/>',
}


def icon(name, size=18, cls="ic"):
    return ('<svg class="%s" width="%d" height="%d" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">%s</svg>' % (cls, size, size, ICONS[name]))


MARK = ('<svg class="mark" width="24" height="24" viewBox="0 0 32 32" aria-hidden="true">'
        '<defs><radialGradient id="lm-a" cx=".38" cy=".34" r=".7"><stop offset="0" stop-color="#fffdf5"/>'
        '<stop offset=".32" stop-color="#ffd27a"/><stop offset=".68" stop-color="#ff7a59"/><stop offset="1" stop-color="#8b5cf6"/></radialGradient>'
        '<radialGradient id="lm-b" cx=".5" cy=".5" r=".5"><stop offset=".55" stop-color="#ffb86b" stop-opacity=".55"/><stop offset="1" stop-color="#ffb86b" stop-opacity="0"/></radialGradient></defs>'
        '<circle cx="16" cy="16" r="16" fill="url(#lm-b)"/><circle cx="16" cy="16" r="10" fill="url(#lm-a)"/>'
        '<circle cx="12.6" cy="12.4" r="2.6" fill="#ffffff" opacity=".9"/></svg>')

GUESTS = [("EB", "#f9a8d4", "#a78bfa"), ("JE", "#fcd34d", "#fb923c"), ("SH", "#6ee7b7", "#3b82f6"),
          ("OA", "#c4b5fd", "#6366f1"), ("LN", "#fda4af", "#f43f5e"), ("KW", "#a5f3fc", "#0ea5e9")]


# initials on the type scale: 12/16 from 28px avatars, 16/24 at 40; smaller ones, and the
# guests in a stack (named in words below it), are plain faces
AVATAR_TYPE = {28: (12, 16), 32: (12, 16), 40: (16, 24)}


def avatar(initials, a, b, size=28, cls="av", letters=True):
    fs, lh = AVATAR_TYPE.get(size, (0, 0)) if letters else (0, 0)
    return ('<span class="%s" style="--a:%s;--b:%s;width:%dpx;height:%dpx%s" aria-hidden="true">%s</span>'
            % (cls, a, b, size, size, ";font-size:%dpx;line-height:%dpx" % (fs, lh) if fs else "", h(initials) if fs else ""))


def when(ev, kind, extra=""):
    """A date of an event, written now and kept current by the page."""
    if kind == "range":
        start = events.starts(ev)
        text = "%s to %s %s" % (events.fmt(start, "time"), events.fmt(events.ends(ev), "time"), events.zone(start.date()))
    elif kind == "deadline":
        import datetime
        text = events.fmt(events.starts(ev) - datetime.timedelta(days=3), "long")
    else:
        text = events.fmt(events.starts(ev), kind)
    return '<span data-ev="%s" data-fmt="%s"%s>%s</span>' % (ev["slug"], kind, extra, h(text))


def head(title, desc):
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<title>%s</title><meta name="description" content="%s">'
            '<meta name="theme-color" content="#fbfaf9"><meta name="color-scheme" content="light">'
            '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
            '<link rel="icon" href="/favicon.png" type="image/png" sizes="64x64">'
            '<link rel="apple-touch-icon" href="/apple-touch-icon.png">'
            '<link rel="stylesheet" href="/assets/lumen.css"></head>' % (h(title), h(desc)))


def nav():
    return ('<header class="nav"><div class="nav-row">'
            '<a class="brand" href="/" aria-label="Lumen, home">%s<span>lumen</span></a>'
            '<nav class="nav-links" aria-label="Main"><a href="/">%s Discover</a><a href="/calendars">%s Calendars</a></nav>'
            '<div class="nav-right"><span class="city">%s Stockholm</span>'
            '<a class="nav-explore" href="/">Explore events %s</a>'
            '<a class="btn btn-soft btn-sm" href="/signin">Sign in</a></div>'
            '</div></header>' % (MARK, icon("compass", 16), icon("calendar", 16), icon("pin", 16), icon("out", 16)))


def footer():
    return ('<footer class="foot"><div class="foot-row"><a class="brand small" href="/">%s<span>lumen</span></a>'
            '<nav aria-label="Footer"><a href="/">Discover</a><a href="/calendars">Calendars</a><a href="/host">Host an event</a>'
            '<a href="/help">Help</a><a href="/help#privacy">Privacy</a><a href="/help#terms">Terms</a></nav>'
            '<span class="foot-copy">© 2026 Lumen</span></div></footer>' % MARK)


def page(title, body, desc="Find events worth leaving the house for.", cls="", tint=""):
    return (head(title, desc) + '<body class="%s"%s>' % (cls, ' style="%s"' % tint if tint else "")
            + nav() + '<main id="main">%s</main>' % body + footer()
            + '<script>window.LUMEN = %s;</script><script src="/assets/lumen.js"></script></body></html>'
            % json.dumps(events.for_script()))


def nowrap(text):
    """Keep a hyphened number with its word: "2-minute" never breaks after "2-"."""
    import re
    return re.sub(r"\b(\d+-[a-z]+)", r'<span class="nw">\1</span>', text)


def hosts_line(ev):
    names = [x[0] for x in ev["hosts"]]
    return " & ".join(names)


# ------------------------------------------------------------------ discover

TAGS = ["Design", "Tech", "AI", "Startups", "Arts & Culture", "Wellness"]


def discover(q="", tag=""):
    upcoming = sorted(events.EVENTS, key=lambda e: events.starts(e))
    if tag in TAGS:
        upcoming = [e for e in upcoming if tag in e["tags"]]
    words = [w for w in q.lower().split() if w]
    if words:
        def hay(e):
            return " ".join([e["title"], e["venue"], e["area"], e["lede"], hosts_line(e), " ".join(e["tags"])]).lower()
        upcoming = [e for e in upcoming if all(w in hay(e) for w in words)]
    days = []
    for ev in upcoming:
        key = events.starts(ev).date()
        if not days or days[-1][0] != key:
            days.append((key, []))
        days[-1][1].append(ev)
    blocks = []
    for key, evs in days:
        first = evs[0]
        cards = []
        for ev in evs:
            av = "".join(avatar(*g, size=20) for g in GUESTS[:4])
            host_avs = "".join(avatar(x[1], x[2], x[3], 20, "av host-av") for x in ev["hosts"])
            cards.append(
                '<a class="ev-card" href="/e/%s">'
                '<div class="ev-info"><p class="ev-time">%s%s</p>'
                '<h3>%s</h3>'
                '<p class="ev-by">%s<span>By %s</span></p>'
                '<p class="ev-where">%s<span>%s, %s</span></p>'
                '<div class="ev-foot"><span class="stack">%s</span><span class="ev-going">+%d going</span>%s</div></div>'
                '<img class="ev-cover" src="/media/covers/%s.svg" alt="" loading="lazy"></a>'
                % (ev["slug"], when(ev, "time"), '<span class="dot"></span><span class="ev-tag">Approval required</span>' if ev["approval"] else "",
                   h(ev["title"]), host_avs, h(hosts_line(ev)), icon("pin", 16), h(ev["venue"]), h(ev["area"].split(",")[0]),
                   av, ev["going"] - 4, '<span class="feat">%s Featured</span>' % icon("sparkle", 16) if ev.get("featured") else "",
                   ev["slug"]))
        blocks.append('<section class="day"><div class="day-label"><span class="day-dot"></span><b>%s</b><span>%s</span></div>'
                      '<div class="day-cards">%s</div></section>'
                      % (when(first, "md"), when(first, "weekday"), "".join(cards)))
    if not blocks:
        blocks.append('<div class="no-events"><b>Nothing matches that yet</b><span>Try another word, or see everything on in Stockholm.</span>'
                      '<a class="btn btn-soft btn-sm" href="/">All events</a></div>')
    chips = [("All", "/")] + [(t, "/?tag=" + t.replace("&", "%26").replace(" ", "+")) for t in TAGS]
    current = tag if tag in TAGS else ("" if q else "All")
    cats = "".join('<a class="cat%s" href="%s"%s>%s</a>' % (" on" if name == current else "", href,
                                                          ' aria-current="page"' if name == current else "", h(name))
                   for name, href in chips)
    cal = ""
    for name, initials, a, b, n in (("Figure Community Stockholm", "FC", "#6d5dfc", "#ff8a65", "4.2k"),
                                     ("Creative Coding Stockholm", "CC", "#22d3ee", "#a855f7", "1.9k"),
                                     ("Product People Sthlm", "PP", "#ec4899", "#f97316", "6.8k")):
        cal += ('<a class="cal" href="/calendars">%s<div><b>%s</b><span>%s subscribers</span></div></a>'
                % (avatar(initials, a, b, 40, "av cal-av"), h(name), n))
    body = ('<div class="disc">'
            '<header class="disc-head"><div><p class="kicker">%s Stockholm</p><h1>Events in Stockholm</h1>'
            '<p class="lede">Talks, meetups and slow mornings this week and next, picked by the people who run them.</p></div>'
            '<form class="disc-search" role="search" action="/" method="get"><label class="sr" for="q">Search events</label>%s'
            '<input id="q" name="q" type="search" placeholder="Search events" autocomplete="off" value="%s"></form></header>'
            '<nav class="cats" aria-label="Categories">%s</nav>'
            '<div class="disc-grid"><div class="timeline">%s</div>'
            '<aside class="disc-side"><h2>Calendars to follow</h2>%s'
            '<div class="host-card"><h3>Host with Lumen</h3><p>Free for community events. Approvals, questions and reminders built in.</p>'
            '<a class="btn btn-soft btn-sm" href="/host">Create an event</a></div></aside></div></div>'
            % (icon("pin", 16), icon("search", 16), h(q), cats, "".join(blocks), cal))
    return page("Discover events in Stockholm · Lumen", body, cls="is-discover")


# ------------------------------------------------------------------ the event

AGENDA = [
    ("17:30", "Doors open", "Fika, name tags and a look around the studio."),
    ("18:00", "Welcome", "Figure Community Stockholm and Tern Labs say hello."),
    ("18:10", "Tokens all the way down", "Sara Holm, design systems lead at Vinter, on naming things for people and machines."),
    ("18:35", "A design system with a team of three", "Oskar Ahl, staff engineer at Brightside, on what they stopped doing."),
    ("19:00", "Lightning demos", "Up to six 2-minute demos from the floor. Ask for a slot when you register."),
    ("19:30", "Drinks and open studio", "Vegetarian food, drinks and alcohol-free options until 21:00."),
]

ABOUT = {
    "design-systems-night": [
        "An evening for the people who build, run and argue about design systems. Two short talks from teams in Stockholm, "
        "a round of 2-minute demos from the floor, and plenty of time to trade notes over drinks.",
        "This is the seventh Design Systems Night. It is free and small on purpose: the hosts approve requests to keep the "
        "room a good mix of designers and engineers, and send the address to everyone on the list.",
    ],
}


def event_page(slug):
    ev = events.BY_SLUG.get(slug)
    if not ev:
        return None
    hosts = "".join('<li>%s<span>%s</span></li>' % (avatar(x[1], x[2], x[3], 28), h(x[0])) for x in ev["hosts"])
    guests = "".join(avatar(*g, size=28, letters=False) for g in GUESTS)
    about = "".join("<p>%s</p>" % nowrap(h(p)) for p in ABOUT.get(slug, [ev["lede"] + " Hosted by " + hosts_line(ev) + "."]))
    agenda = ""
    if slug == "design-systems-night":
        agenda = ('<h3 class="sub">Agenda</h3><ol class="agenda">%s</ol>'
                  % "".join('<li><time>%s</time><div><b>%s</b><span>%s</span></div></li>' % (t, h(a), nowrap(h(b))) for t, a, b in AGENDA))
    approval = ""
    if ev["approval"]:
        approval = ('<div class="approval">%s<div><b>Approval required</b><span>Your registration is subject to approval by the hosts.</span></div></div>'
                    % '<span class="approval-ic">%s</span>' % icon("approve", 20))
    tint = ""
    if slug == "design-systems-night":
        tint = ("background-image: radial-gradient(900px 520px at 12% -10%, rgba(124, 92, 252, .16), transparent 70%), "
                "radial-gradient(800px 480px at 92% -6%, rgba(255, 138, 101, .14), transparent 70%)")
    body = (
        '<div class="event">'
        '<div class="event-grid">'
        '<aside class="event-side">'
        '<img class="cover" src="/media/covers/%s.svg" alt="Poster for %s">'
        '<section class="side-block"><h2 class="side-title">Hosted by</h2><ul class="hosts">%s</ul>'
        '<div class="side-links"><a href="#contact">%s Contact the hosts</a></div></section>'
        '<section class="side-block"><h2 class="side-title">%d going</h2>'
        '<div class="going"><span class="stack big">%s</span><span class="going-more">+%d going</span></div>'
        '<p class="going-names">Elin Berg, Jonas Ek and %d others</p></section>'
        '<div class="side-links muted"><a href="#report">%s Report event</a></div>'
        '</aside>'
        '<section class="event-main">'
        '%s'
        '<h1>%s</h1>'
        '<div class="facts">'
        '<div class="fact"><div class="date-tile"><span>%s</span><b>%s</b></div><div><b>%s</b><span>%s</span></div></div>'
        '<div class="fact"><div class="pin-tile">%s</div><div><b>%s %s</b><span>%s</span></div></div>'
        '</div>'
        '<section class="reg-card" aria-labelledby="reg-title"><h2 id="reg-title" class="reg-head">Registration</h2>'
        '<div class="reg-body">%s'
        '<p class="reg-welcome">Welcome! To join the event, please register below.</p>'
        '<a class="btn btn-dark btn-block" href="/e/%s/register">%s</a>'
        '<p class="reg-note">%s<span>Free · Requests reviewed by %s</span></p>'
        '</div></section>'
        '<section class="about"><h2 class="sec-title">About event</h2>%s%s</section>'
        '<section class="location" id="location"><h2 class="sec-title">Location</h2>'
        '<p class="loc-name">%s</p><p class="loc-sub">%s</p>'
        '<div class="map"><img src="/media/maps/%s.svg" alt="Map of %s, %s"></div>'
        '<p class="loc-note">The street address goes to approved guests. Ring the bell marked Hyllie, second floor; the courtyard entrance has no steps.</p>'
        '</section>'
        '<section class="contact" id="contact"><h2 class="sec-title">Hosted by</h2><div class="host-row">%s</div></section>'
        '</section></div></div>'
        % (slug, h(ev["short"]), hosts, icon("mail", 16), ev["going"], guests, ev["going"] - 6, ev["going"] - 2, icon("flag", 16),
           '<a class="featured" href="/">%s Featured in Stockholm %s</a>' % (icon("sparkle", 16), icon("out", 16)) if ev.get("featured") else "",
           h(ev["title"]),
           when(ev, "month"), when(ev, "day"), when(ev, "long"), when(ev, "range"),
           icon("pin", 20), h(ev["venue"]), icon("out", 16), h(ev["area"]),
           approval, slug, "Request to join" if ev["approval"] else "Register",
           icon("ticket", 16), when(ev, "deadline"),
           about, agenda, h(ev["venue"]), h(ev["area"]), slug, h(ev["venue"]), h(ev["area"]),
           "".join('<div class="host-chip">%s<div><b>%s</b><span>%s</span></div><a class="btn btn-soft btn-sm" href="#subscribe">Subscribe</a></div>'
                   % (avatar(x[1], x[2], x[3], 40), h(x[0]), "Community" if "Community" in x[0] else "Host")
                   for x in ev["hosts"])))
    return page("%s · Lumen" % ev["title"], body, desc=ev["lede"], cls="is-event", tint=tint)


# ------------------------------------------------------------------ the form

def register_page(slug, values=None, errors=None):
    ev = events.BY_SLUG.get(slug)
    if not ev:
        return None
    v = values or {}
    e = errors or {}

    def err(name):
        msg = e.get(name)
        return '<p class="err" id="err-%s"%s>%s</p>' % (name, "" if msg else " hidden", h(msg or ""))

    def inv(name):
        return ' aria-invalid="true" aria-describedby="err-%s"' % name if e.get(name) else ""

    def text_field(name, label, auto="", kind="text", placeholder="", required=False, extra="", hint=""):
        return ('<div class="field%s"><label for="%s">%s%s</label>'
                '<input id="%s" name="%s" type="%s"%s%s%s value="%s"%s%s>%s%s</div>'
                % (" bad" if e.get(name) else "", name, h(label), ' <span class="req">*</span>' if required else "",
                   name, name, kind, ' autocomplete="%s"' % auto if auto else "",
                   ' placeholder="%s"' % h(placeholder) if placeholder else "", " required" if required else "",
                   h(v.get(name, "")), extra, inv(name), '<p class="hint">%s</p>' % hint if hint else "", err(name)))

    def area(name, label, hint=""):
        return ('<div class="field%s"><label for="%s">%s <span class="req">*</span></label>'
                '<textarea id="%s" name="%s" rows="3" required%s>%s</textarea>%s%s</div>'
                % (" bad" if e.get(name) else "", name, h(label), name, name, inv(name), h(v.get(name, "")),
                   '<p class="hint">%s</p>' % hint if hint else "", err(name)))
    demo = v.get("demo_slot", "")
    asks = ev.get("questions")
    if asks:
        questions = ('<fieldset class="group"><legend>Questions from the hosts</legend>%s%s'
                     '<fieldset class="field radios"><legend>Want a 2-minute demo slot?</legend>'
                     '<div class="radio-row"><label class="choice"><input type="radio" name="demo_slot" value="yes"%s><span>Yes</span></label>'
                     '<label class="choice"><input type="radio" name="demo_slot" value="no"%s><span>No</span></label></div>'
                     '<p class="hint">The hosts pick up to six demos and let you know the day before.</p></fieldset>%s</fieldset>'
                     % (area("working_on", "What are you working on right now?"),
                        area("hoping_for", "What do you hope to get out of the night?"),
                        " checked" if demo == "yes" else "", " checked" if demo == "no" else "",
                        text_field("dietary", "Dietary restrictions", "", "text", "Vegetarian, no nuts…")))
    else:
        questions = ('<fieldset class="group"><legend>For the hosts</legend>%s</fieldset>'
                     % text_field("dietary", "Dietary restrictions", "", "text", "Vegetarian, no nuts…"))
    verb = "Request to join" if ev["approval"] else "Register"
    updates = v.get("updates", "yes" if not values else "")
    consent = v.get("consent", "")
    alert = ""
    if e:
        alert = '<div class="form-alert" role="alert">%s Please fill in the fields marked below.</div>' % icon("flag", 16)
    body = (
        '<div class="reg-page">'
        '<a class="back" href="/e/%s">%s Back to event</a>'
        '<div class="reg-event"><img src="/media/covers/%s.svg" alt="">'
        '<div><p class="reg-when">%s · %s</p><h1>%s</h1><p class="reg-where">%s %s, %s</p></div></div>'
        '<form class="reg-form" id="register" method="post" action="/e/%s/register" novalidate>'
        '<div class="form-head"><h2>%s</h2><p>%s '
        '<span class="nw">Fields marked <span class="req">*</span> are required.</span></p></div>'
        '%s'
        '<fieldset class="group"><legend>Your info</legend>'
        '%s%s'
        '<div class="two">%s%s</div>'
        '<div class="two">%s%s</div>'
        '%s'
        '</fieldset>'
        '%s'
        '<div class="ticks">'
        '<label class="tick"><input type="checkbox" name="updates" value="yes"%s><span>Send me updates from the hosts</span></label>'
        '<label class="tick%s"><input type="checkbox" name="consent" value="yes" required%s%s>'
        '<span>I agree to share my name, email and answers with the hosts <span class="req">*</span></span></label>'
        '%s</div>'
        '<button class="btn btn-dark btn-block btn-lg" type="submit" data-send>%s</button>'
        '<p class="fine">%s</p>'
        '</form></div>'
        % (slug, icon("back", 16), slug, when(ev, "long"), when(ev, "time"), h(ev["title"]), icon("pin", 16), h(ev["venue"]),
           h(ev["area"].split(",")[0]), slug, verb,
           ("The hosts read every request and confirm spots by %s." % when(ev, "deadline")) if ev["approval"]
           else "Your spot is saved as soon as you register.", alert,
           text_field("name", "Name", "name", required=True),
           text_field("email", "Email", "email", "email", required=True, extra=' spellcheck="false"'),
           text_field("company", "Company", "organization"),
           text_field("job_title", "Job title", "organization-title"),
           text_field("linkedin", "LinkedIn", "", "text", "linkedin.com/in/...", extra=' inputmode="url" spellcheck="false"'),
           text_field("x_handle", "X", "", "text", "@username", extra=' spellcheck="false"'),
           text_field("website", "Website", "url", "url", "https://", extra=' spellcheck="false"'),
           questions,
           " checked" if updates else "",
           " bad" if e.get("consent") else "", " checked" if consent else "", inv("consent"), err("consent"),
           verb, "You can withdraw your request anytime from the email we send you." if ev["approval"]
           else "You can cancel anytime from the email we send you."))
    return page("%s: %s · Lumen" % (verb, ev["title"]), body, desc=ev["lede"], cls="is-register")


ANSWER_LABELS = [
    ("name", "Name"), ("email", "Email"), ("company", "Company"), ("job_title", "Job title"),
    ("linkedin", "LinkedIn"), ("x_handle", "X"), ("website", "Website"), ("dietary", "Dietary restrictions"),
    ("working_on", "What are you working on right now?"), ("hoping_for", "What do you hope to get out of the night?"),
    ("demo_slot", "Want a 2-minute demo slot?"), ("updates", "Updates from the hosts"),
]


def done_page(slug, reg):
    ev = events.BY_SLUG.get(slug)
    if not ev:
        return None
    rows = ""
    if reg:
        for key, label in ANSWER_LABELS:
            if not ev.get("questions") and key in ("working_on", "hoping_for", "demo_slot"):
                continue
            val = reg.get(key, "").strip()
            if key == "demo_slot":
                val = {"yes": "Yes", "no": "No"}.get(val, "")
            if key == "updates":
                val = "Yes" if val else "No"
            empty = not val
            rows += '<div class="ans%s"><dt>%s</dt><dd>%s</dd></div>' % (" long" if key in ("working_on", "hoping_for") else "",
                                                                         h(label), h(val) if not empty else '<span class="none">Not shared</span>')
    first = (reg or {}).get("name", "").split(" ")[0] if reg else ""
    email = (reg or {}).get("email", "")
    answers = ""
    if rows:
        answers = ('<section class="answers"><div class="answers-head"><h2>Your answers</h2>'
                   '<a class="btn btn-soft btn-sm" href="/e/%s/register?edit=%s">%s Edit</a></div><dl>%s</dl></section>'
                   % (slug, h(reg.get("id", "")), icon("edit", 16), rows))
    body = (
        '<div class="done-page">'
        '<section class="done-card">'
        '<div class="done-top"><img class="done-cover" src="/media/covers/%s.svg" alt="">'
        '<div class="done-badge">%s</div></div>'
        '%s'
        '<h1>%s</h1>'
        '<p class="done-lede">%s</p>'
        '<div class="done-facts">'
        '<div class="fact"><div class="date-tile"><span>%s</span><b>%s</b></div><div><b>%s</b><span>%s</span></div></div>'
        '<div class="fact"><div class="pin-tile">%s</div><div><b>%s</b><span>%s</span></div></div></div>'
        '<div class="done-actions"><a class="btn btn-dark" href="/e/%s/calendar.ics" download="%s.ics">%s Add to calendar</a>'
        '<a class="btn btn-soft" href="/e/%s">View event</a></div>'
        '</section>%s'
        '<p class="done-foot">Changed your plans? <a href="/e/%s">Cancel your spot</a> and someone on the waitlist gets it.</p>'
        '</div>'
        % (slug, icon("check", 20),
           '<p class="pill pending"><span></span>Pending approval</p>' if ev["approval"] else '<p class="pill going"><span></span>Registered</p>',
           "You’re on the list" if ev["approval"] else "You’re going",
           (("Thanks, %s. " % h(first)) if first else "") + (
               "The hosts review every request and confirm spots by %s.%s" % (
                   when(ev, "deadline"), (" We’ll email <b>%s</b> either way." % h(email)) if email else "")
               if ev["approval"] else
               "See you on %s. We’ll send a reminder%s the day before." % (
                   when(ev, "long"), (" to <b>%s</b>" % h(email)) if email else "")),
           when(ev, "month"), when(ev, "day"), when(ev, "long"), when(ev, "range"),
           icon("pin", 20), h(ev["venue"]), h(ev["area"]),
           slug, slug, icon("calendar", 16), slug, answers, slug))
    return page("%s: %s · Lumen" % ("You’re on the list" if ev["approval"] else "You’re going", ev["short"]), body, cls="is-done")


def simple(title, heading, text, extra=""):
    body = ('<div class="simple"><h1>%s</h1><p>%s</p>%s<p><a class="btn btn-soft" href="/">%s Back to events</a></p></div>'
            % (h(heading), text, extra, icon("back", 16)))
    return page("%s · Lumen" % title, body, cls="is-simple")


def signin():
    extra = ('<form class="signin" method="get" action="/signin" data-signin><label for="si-email">Email</label>'
             '<input id="si-email" name="email" type="email" autocomplete="email" placeholder="you@example.com">'
             '<button class="btn btn-dark btn-block" type="submit">Continue with email</button>'
             '<p class="signin-done" hidden>Check your inbox: we sent you a link to sign in.</p></form>')
    return simple("Sign in", "Welcome to Lumen", "Sign in or create an account with your email. No password needed.", extra)


def not_found():
    return simple("Page not found", "This page took the night off",
                  "The event may have moved or ended. Have a look at what is on in Stockholm instead.")
