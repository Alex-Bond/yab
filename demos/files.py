"""Mira's files: real PDFs and pictures, for her downloads and the home the
file picker shows in a demo world (RecentFiles.standIn).

Each is drawn once from a small page of HTML by headless Chrome and kept in
~/Library/Caches/yab-demo/files; a world gets copies, dated as PLACES says.
"""
import datetime as dt
import hashlib
import os
import subprocess
import tempfile
import zipfile
from pathlib import Path

CACHE = Path.home() / "Library/Caches/yab-demo/files"
CHROMES = ["/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
           "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
           "/Applications/Chromium.app/Contents/MacOS/Chromium"]

BASE = """<!doctype html><meta charset=utf-8><style>
@page { margin: 0 }
* { box-sizing: border-box }
body { margin: 0; font: 13px/1.5 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; color: #17181a; -webkit-print-color-adjust: exact }
h1, h2, h3 { margin: 0; font-weight: 650; letter-spacing: -0.01em }
.muted { color: #6b6f76 } .right { text-align: right } table { width: 100%; border-collapse: collapse }
td, th { padding: 9px 0; border-bottom: 1px solid #ececef; text-align: left; font-weight: 450 } th { color: #6b6f76; font-weight: 500; font-size: 12px }
</style>"""

INVOICE = BASE + """<body style="padding:56px 64px">
<div style="display:flex;justify-content:space-between;align-items:flex-start">
 <div><div style="display:flex;align-items:center;gap:10px"><svg width=28 height=28 viewBox="0 0 28 28"><rect width=28 height=28 rx=7 fill="#3b4bd8"/><path d="M8 9h12M8 14h12M8 19h7" stroke="#fff" stroke-width=2.2 stroke-linecap=round /></svg><b style="font-size:17px">Tern Labs AB</b></div>
 <p class=muted>Hornsgatan 45, 118 49 Stockholm<br>billing@ternlabs.com · VAT SE559312874401</p></div>
 <div class=right><h1 style="font-size:30px">Invoice</h1><p class=muted>INV-2026-0918<br>Issued Sep 18, 2026 · Due Oct 2, 2026</p></div></div>
<div style="display:flex;gap:64px;margin:36px 0 28px"><div><div class=muted>Billed to</div><b>Northwind Studio</b><br>Linnégatan 18<br>114 47 Stockholm</div>
<div><div class=muted>Plan</div><b>Tern Team, annual</b><br>12 seats</div></div>
<table><tr><th>Description</th><th>Qty</th><th class=right>Price</th><th class=right>Amount</th></tr>
<tr><td>Tern Team seat, annual</td><td>12</td><td class=right>$96.00</td><td class=right>$1,152.00</td></tr>
<tr><td>Focus insights add-on</td><td>1</td><td class=right>$240.00</td><td class=right>$240.00</td></tr>
<tr><td>Onboarding workshop</td><td>1</td><td class=right>$400.00</td><td class=right>$400.00</td></tr></table>
<div style="margin-left:auto;width:260px;margin-top:18px"><table><tr><td class=muted>Subtotal</td><td class=right>$1,792.00</td></tr>
<tr><td class=muted>VAT 25%</td><td class=right>$448.00</td></tr><tr><td><b>Total due</b></td><td class=right><b style="font-size:18px">$2,240.00</b></td></tr></table></div>
<p class=muted style="margin-top:60px">Pay by card at ledger.localtest.me/pay/INV-2026-0918 or by bank transfer to Tern Labs AB, IBAN SE45 5000 0000 0583 9825 7466. Thank you!</p></body>"""

DECK = BASE + """<style>@page { size: 1280px 720px } section { width:1280px; height:720px; padding:80px 96px; page-break-after: always; position:relative; overflow:hidden }</style><body>
<section style="background:linear-gradient(135deg,#0f1b3d,#27407a 55%,#7aa0e8)"><div style="color:#cfdaf6;font-size:20px">Tern Labs · October 2026</div>
<h1 style="color:#fff;font-size:88px;margin-top:150px;line-height:1">Tern 2.0</h1><div style="color:#e7eefc;font-size:30px;margin-top:20px">Focus first. Meetings fit around it.</div>
<svg style="position:absolute;right:-80px;bottom:-60px" width=620 height=420><path d="M20 380 C 180 120, 360 120, 600 40" stroke="#fff" stroke-opacity=.35 stroke-width=3 fill=none /><path d="M60 400 C 220 200, 380 180, 620 120" stroke="#fff" stroke-opacity=.2 stroke-width=2 fill=none /></svg></section>
<section style="background:#f6f7fb"><h2 style="font-size:44px">What's new</h2><div style="display:grid;grid-template-columns:repeat(3,1fr);gap:28px;margin-top:56px">
<div style="background:#fff;border-radius:20px;padding:32px;height:330px"><div style="width:52px;height:52px;border-radius:14px;background:#e4ebff"></div><h3 style="font-size:24px;margin-top:28px">Focus blocks</h3><p class=muted style="font-size:17px">Tern protects two hours a day before anyone can book you.</p></div>
<div style="background:#fff;border-radius:20px;padding:32px;height:330px"><div style="width:52px;height:52px;border-radius:14px;background:#e3f6ec"></div><h3 style="font-size:24px;margin-top:28px">One-screen onboarding</h3><p class=muted style="font-size:17px">Connect a calendar in the first minute, invite the team later.</p></div>
<div style="background:#fff;border-radius:20px;padding:32px;height:330px"><div style="width:52px;height:52px;border-radius:14px;background:#fdf0e1"></div><h3 style="font-size:24px;margin-top:28px">Team insights</h3><p class=muted style="font-size:17px">See where meetings eat the week, and win it back.</p></div></div></section>
<section style="background:#fff"><h2 style="font-size:44px">Rollout</h2><div style="margin-top:70px;position:relative;height:6px;background:#e7e9f0;border-radius:3px"><div style="width:58%;height:6px;background:#3b4bd8;border-radius:3px"></div></div>
<div style="display:flex;justify-content:space-between;margin-top:26px;font-size:19px"><div><b>Oct 9</b><div class=muted>10% of new teams</div></div><div><b>Oct 14</b><div class=muted>50%, pricing live</div></div><div><b>Oct 21</b><div class=muted>Everyone, launch post</div></div></div></section></body>"""

BOOKING = BASE + """<body style="padding:56px 64px"><div style="display:flex;justify-content:space-between;align-items:center"><b style="font-size:20px;color:#c2410c">Casa Alfama</b><span class=muted>Reservation CA-55821</span></div>
<div style="margin-top:28px;height:220px;border-radius:18px;background:linear-gradient(160deg,#f9d9b6,#e9a979 45%,#9c5f43);position:relative;overflow:hidden">
<svg width=100% height=220 viewBox="0 0 700 220" preserveAspectRatio=none><path d="M0 170 L80 120 L140 150 L210 90 L300 140 L380 80 L470 130 L560 70 L700 120 L700 220 L0 220Z" fill="#7a3f2a" fill-opacity=.55 /><path d="M0 195 L120 160 L250 185 L360 150 L520 180 L700 150 L700 220 L0 220Z" fill="#4a2418" fill-opacity=.6 /></svg></div>
<h1 style="font-size:28px;margin-top:26px">Your stay in Alfama is confirmed</h1><p class=muted>Rua de São Miguel 21, 1100-544 Lisboa, Portugal</p>
<table style="margin-top:18px"><tr><td class=muted>Guest</td><td>Mira Lindqvist</td></tr><tr><td class=muted>Check-in</td><td>{go}, from 15:00</td></tr><tr><td class=muted>Check-out</td><td>{back}, by 11:00</td></tr>
<tr><td class=muted>Room</td><td>Terrace studio, river view</td></tr><tr><td class=muted>4 nights</td><td>€784.00</td></tr><tr><td><b>Total paid</b></td><td><b>€812.00</b></td></tr></table>
<p class=muted style="margin-top:30px">Your host Inês will send the key box code the day before you arrive.</p></body>"""

FLIGHT = BASE + """<body style="padding:56px 64px"><div style="display:flex;justify-content:space-between"><b style="font-size:20px;color:#0b2a6f">Nordic Air</b><span class=muted>Receipt · Booking LQ4K2P</span></div>
<h1 style="font-size:26px;margin-top:30px">Stockholm Arlanda to Copenhagen, return</h1><p class=muted>Passenger: Mira Lindqvist · Window seats 7A, 9F · Config Copenhagen</p>
<div style="display:flex;gap:20px;margin-top:22px"><div style="flex:1;border:1px solid #e6e8ee;border-radius:14px;padding:18px"><div class=muted>Sep 22 · NA 412</div><b style="font-size:22px">ARN 07:10</b> → <b style="font-size:22px">CPH 08:20</b></div>
<div style="flex:1;border:1px solid #e6e8ee;border-radius:14px;padding:18px"><div class=muted>Sep 23 · NA 419</div><b style="font-size:22px">CPH 19:05</b> → <b style="font-size:22px">ARN 20:15</b></div></div>
<table style="margin-top:22px"><tr><td>Fare, Go Light x2</td><td class=right>€152.00</td></tr><tr><td>Seat selection x2</td><td class=right>€24.00</td></tr><tr><td>Taxes and fees</td><td class=right>€13.00</td></tr><tr><td><b>Total charged to Amex 0005</b></td><td class=right><b>€189.00</b></td></tr></table></body>"""

TAXI = BASE + """<body style="padding:40px;width:420px;margin:0 auto"><div style="text-align:center"><b style="font-size:22px">Taxi Kurir Stockholm</b><p class=muted>Org.nr 556123-4567<br>Sep 24, 2026 · 18:42</p></div>
<table><tr><td>From</td><td class=right>Arlanda Terminal 5</td></tr><tr><td>To</td><td class=right>Södermannagatan 12</td></tr><tr><td>Distance</td><td class=right>44.2 km</td></tr><tr><td>Fixed price</td><td class=right>675.00 kr</td></tr><tr><td>VAT 6%</td><td class=right>38.21 kr</td></tr><tr><td><b>Total</b></td><td class=right><b>675.00 kr</b></td></tr></table>
<p class=muted style="text-align:center;margin-top:24px">Paid by card · Visa **** 4242<br>Thank you for riding with us</p></body>"""

LUNCH = BASE + """<body style="background:#e9e4dc;padding:40px"><div style="width:380px;margin:0 auto;background:#fffdf8;padding:30px;box-shadow:0 10px 30px rgba(0,0,0,.18);transform:rotate(-1.5deg);font-family:Menlo,monospace;font-size:13px">
<div style="text-align:center"><b style="font-size:18px">CAFÉ PASCAL</b><br>Norrtullsgatan 4, Stockholm<br>2026-09-26 12:31</div><hr style="border:none;border-top:1px dashed #999">
<div style="display:flex;justify-content:space-between"><span>2 x Dagens lunch</span><span>270.00</span></div><div style="display:flex;justify-content:space-between"><span>2 x Bryggkaffe</span><span>70.00</span></div>
<div style="display:flex;justify-content:space-between"><span>1 x Kanelbulle</span><span>42.00</span></div><hr style="border:none;border-top:1px dashed #999">
<div style="display:flex;justify-content:space-between;font-weight:700"><span>TOTAL SEK</span><span>382.00</span></div><div style="text-align:center;margin-top:16px">Kort: MASTERCARD ****4444<br>Tack för besöket!</div></div></body>"""

CV = BASE + """<body style="padding:64px"><h1 style="font-size:34px">Mira Lindqvist</h1><p style="font-size:16px">Founding Designer · Stockholm · mira@lindqvist.studio · lindqvist.studio</p>
<h3 style="margin-top:34px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#6b6f76">Experience</h3>
<p><b>Tern Labs</b>, Founding Designer · 2024 to now<br><span class=muted>Calm scheduling for teams. Product, brand and the design system from zero to 2.0.</span></p>
<p><b>Kiln</b>, Senior Product Designer · 2018 to 2024<br><span class=muted>Led the design system used by 40 engineers; tokens, components, docs.</span></p>
<p><b>Northwind Studio</b>, Designer · 2015 to 2018<br><span class=muted>Brand and web for Nordic cultural institutions.</span></p>
<h3 style="margin-top:28px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#6b6f76">Education</h3><p><b>Konstfack</b>, MFA Interaction Design · 2015</p>
<h3 style="margin-top:28px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#6b6f76">Talks</h3><p>Calm by default, Design Systems Night 2025 · Tokens that age well, Config Stockholm 2024</p></body>"""

PORTFOLIO = BASE + """<style>@page { size: 1280px 800px } section { width:1280px; height:800px; padding:90px; page-break-after:always }</style><body>
<section style="background:#111"><div style="color:#888;font-size:18px">Portfolio 2026</div><h1 style="color:#fff;font-size:96px;margin-top:220px">Mira Lindqvist</h1><div style="color:#aaa;font-size:26px">Calm, dense tools for small teams</div></section>
<section style="background:#f3efe8"><h2 style="font-size:40px">Tern · scheduling</h2><div style="display:grid;grid-template-columns:2fr 1fr;gap:30px;margin-top:40px"><div style="height:480px;border-radius:24px;background:linear-gradient(140deg,#dfe7ff,#b8c8f5)"></div><div style="display:grid;gap:30px"><div style="border-radius:24px;background:#e9dcc8"></div><div style="border-radius:24px;background:#cfe3d6"></div></div></div></section>
<section style="background:#fff"><h2 style="font-size:40px">Kiln · design system</h2><div style="display:grid;grid-template-columns:repeat(4,1fr);gap:22px;margin-top:40px">""" + "".join(
    '<div style="height:200px;border-radius:18px;background:hsl(%d,55%%,86%%)"></div>' % (h * 37 % 360) for h in range(8)) + "</div></section></body>"

WELCOME = BASE + """<body style="background:#eef1f7;width:1600px;height:1000px;display:flex;align-items:center;justify-content:center">
<div style="width:1180px;height:760px;background:#fff;border-radius:28px;box-shadow:0 30px 80px rgba(20,30,60,.18);display:grid;grid-template-columns:1fr 1fr;overflow:hidden">
<div style="padding:80px"><div style="width:44px;height:44px;border-radius:12px;background:#3b4bd8"></div><h1 style="font-size:46px;margin-top:70px;line-height:1.1">Welcome to Tern.<br>Let's protect your focus.</h1>
<p class=muted style="font-size:19px;margin-top:20px">Connect your calendar and Tern finds the hours worth keeping.</p>
<div style="margin-top:44px;display:inline-block;background:#17181a;color:#fff;padding:16px 26px;border-radius:14px;font-size:17px">Connect Google Calendar</div></div>
<div style="background:linear-gradient(160deg,#dfe6ff,#f6efe4);padding:60px"><div style="background:#fff;border-radius:18px;height:100%;padding:26px;display:grid;gap:12px">""" + "".join(
    '<div style="border-radius:10px;background:%s"></div>' % c for c in ["#e6ebff", "#dff3e8", "#fff", "#e6ebff", "#fde9d6", "#fff"]) + "</div></div></div></body>"

MOODBOARD = BASE + """<body style="width:1800px;height:1200px;background:#f4f1ec;padding:50px;display:grid;grid-template-columns:repeat(4,1fr);grid-auto-rows:350px;gap:26px">""" + "".join(
    '<div style="border-radius:20px;background:%s;%s"></div>' % (bg, span) for bg, span in [
        ("linear-gradient(160deg,#d8c3a5,#a47d5a)", "grid-row:span 2"), ("#2b3a55", ""), ("linear-gradient(120deg,#f2d0a4,#e6a57e)", ""),
        ("#cfd8c3", "grid-row:span 2"), ("radial-gradient(circle at 30% 30%,#fff,#d9e1f2)", ""), ("#e8e1d7", ""),
        ("linear-gradient(180deg,#8fa3c8,#4a5f8a)", ""), ("#c9b8a6", "")]) + "</body>"

NOTES = BASE + """<body style="padding:64px"><div class=muted>Paper · Tern Labs / Onboarding</div><h1 style="font-size:30px;margin-top:10px">Onboarding v3 notes</h1>
<p>One welcome screen instead of four. The calendar is connected in the first minute, the team comes later.</p><ul><li>Drop the role question, guess it from the calendar.</li><li>Empty state for teams with no calendars connected.</li><li>Measure: time to first booking, not sign-up completion.</li></ul>
<h3 style="margin-top:24px">Open questions</h3><ul><li>Do we ask for focus hours on day one?</li><li>What does the error say when Google says no?</li></ul></body>"""

import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parent))
import persona as _persona  # noqa: E402
_go, _back = _persona.trip(dt.datetime.now().timestamp())
BOOKING = BOOKING.replace("{go}", _go.strftime("%b %-d")).replace("{back}", _back.strftime("%b %-d"))

TEMPLATES = {
    "invoice": ("pdf", INVOICE, None), "deck": ("pdf", DECK, None), "booking": ("pdf", BOOKING, None),
    "flight": ("pdf", FLIGHT, None), "taxi": ("pdf", TAXI, None), "cv": ("pdf", CV, None),
    "portfolio": ("pdf", PORTFOLIO, None), "notes": ("pdf", NOTES, None),
    "lunch": ("png", LUNCH, (900, 1100)), "welcome": ("png", WELCOME, (1600, 1000)), "moodboard": ("png", MOODBOARD, (1800, 1200)),
}

NOW = dt.datetime.now()
SHOT = "Screenshot %s at %s.png" % (NOW.strftime("%Y-%m-%d"), NOW.strftime("%H.%M.%S"))

# Where each lands: (place, name, made from, minutes ago, page it came from, its title).
PLACES = [
    ("Downloads", "Tern-2.0-launch-deck.pdf", "deck", 40, "http://paper.localtest.me:8800/d/launch-notes", "Launch notes · Tern 2.0 · Paper"),
    ("Downloads", "Onboarding-v3-welcome@2x.png", "welcome", 125, "https://www.figma.com/design/xK29fLm8Qe3pRtV7/Onboarding-v3",
     "Onboarding v3 · Welcome screens · Figma"),
    ("Downloads", "invoice-INV-2026-0918.pdf", "invoice", 26 * 60, "http://ledger.localtest.me:8800/invoices", "Invoices · Ledger"),
    ("Downloads", "Nordic-Air-receipt-LQ4K2P.pdf", "flight", 4 * 1440, "https://www.google.com/travel/flights/bookings",
     "Bookings · Google Flights"),
    ("Downloads", "Casa-Alfama-booking.pdf", "booking", 3 * 1440, "https://www.airbnb.com/trips", "Trips · Airbnb"),
    ("Downloads", "tern-brand-assets.zip", "zip", 5 * 1440, "https://www.figma.com/files/team/1189/recents-and-sharing", "Recents · Figma"),
    ("Desktop", SHOT, "shot", 3, None, None),
    ("Desktop", "Moodboard, welcome.png", "moodboard", 2 * 1440, None, None),
    ("Documents", "Mira Lindqvist CV.pdf", "cv", 30 * 1440, None, None),
    ("Documents", "Portfolio 2026.pdf", "portfolio", 12 * 1440, None, None),
    ("Documents", "Receipts/Taxi Arlanda 2026-09-24.pdf", "taxi", 6 * 1440, None, None),
    ("Documents", "Receipts/Lunch with Kai.png", "lunch", 4 * 1440, None, None),
    ("Documents", "Tern/Onboarding v3 notes.pdf", "notes", 2 * 1440, None, None),
]


def chrome():
    for path in CHROMES:
        if os.path.exists(path):
            return path
    raise SystemExit("demos/files.py needs Google Chrome (or Chrome Beta) to draw Mira's files.")


def render(kind, html, size, out):
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "page.html"
        page.write_text(html)
        args = [chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--user-data-dir=" + tmp + "/p"]
        if kind == "pdf":
            args += ["--no-pdf-header-footer", "--print-to-pdf=" + str(out), page.as_uri()]
        else:
            args += ["--window-size=%d,%d" % size, "--screenshot=" + str(out), page.as_uri()]
        subprocess.run(args, capture_output=True, timeout=60)


def screenshot(out):
    """What Mira just grabbed of her screen: Tern's site in the making, if
    the dev server answers, else the welcome screen."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--window-size=1512,945",
                        "--user-data-dir=" + tmp, "--screenshot=" + str(out), "http://localhost:5173/"], capture_output=True, timeout=60)
    if not out.exists() or out.stat().st_size < 20000:
        render("png", WELCOME, (1512, 945), out)


def brand_zip(out):
    mark = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="16" fill="%s"/><path d="M14 38c8-14 22-20 36-16-10 2-18 8-22 18" fill="none" stroke="%s" stroke-width="5" stroke-linecap="round"/></svg>'
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, bg, fg in [("tern-mark.svg", "#3b4bd8", "#fff"), ("tern-mark-dark.svg", "#111", "#fff"), ("tern-mark-light.svg", "#fff", "#3b4bd8")]:
            z.writestr("tern-brand-assets/" + name, mark % (bg, fg))
        z.writestr("tern-brand-assets/README.txt", "Tern brand assets, 2.0. Use the mark on its own or with the wordmark.\n")


def make():
    """Every file, drawn if the cache lacks it: {source: path}."""
    CACHE.mkdir(parents=True, exist_ok=True)
    out = {}
    for name, (kind, html, size) in TEMPLATES.items():
        digest = hashlib.md5(html.encode()).hexdigest()[:8]
        target = CACHE / ("%s-%s.%s" % (name, digest, kind))
        if not target.exists():
            render(kind, html, size, target)
        out[name] = target
    shot = CACHE / ("shot-%s.png" % NOW.strftime("%Y%m%d"))
    if not shot.exists():
        screenshot(shot)
    out["shot"] = shot
    archive = CACHE / "brand.zip"
    if not archive.exists():
        brand_zip(archive)
    out["zip"] = archive
    return out


if __name__ == "__main__":
    for name, path in make().items():
        print("%-10s %s (%d KB)" % (name, path, path.stat().st_size // 1024))
