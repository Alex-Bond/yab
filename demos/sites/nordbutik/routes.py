"""Nordbutik, a Scandinavian design shop: pages written on the server,
pictures drawn on request, a checkout that takes a card, and invoices and
care guides as PDFs that download slowly enough to watch."""
import datetime
import importlib.util
import json
import re
import sys
import tempfile
import threading
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name):
    key = "nordbutik_" + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, HERE / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[key] = module
        spec.loader.exec_module(module)
    return sys.modules[key]


catalog = _load("catalog")
art = _load("art")
pdf = _load("pdf")
pages = _load("pages")
pages.catalog = catalog

RATE = 150000          # bytes a second, so the download's ring fills visibly
PDF_SIZE = 410000
TMP = Path(tempfile.gettempdir()) / "yab-demo-nordbutik"
LOCK = threading.Lock()
ORDERS = {}
NEXT = [48391]
MEDIA = {}


def _item(slug, color, qty):
    p = catalog.BY_SLUG[slug]
    c = catalog.color(p, color)
    return {"slug": slug, "name": p["name"], "color": c[0], "color_name": c[1], "price": p["price"], "qty": qty}


def _seeded():
    """Orders Mira placed before the demo begins."""
    m = pages.MIRA
    addr = {"name": m["name"], "line1": m["line1"], "postal": m["postal"], "city": m["city"], "country": m["country"]}
    out = []
    for number, placed, delivered, items in (
        ("48213", datetime.datetime(2026, 8, 14, 20, 41), datetime.date(2026, 8, 18),
         [_item("oak-serving-board", "natural", 1), _item("linen-apron", "sand", 1)]),
        ("47760", datetime.datetime(2026, 6, 2, 9, 12), datetime.date(2026, 6, 5),
         [_item("tern-ceramic-mug", "chalk", 2), _item("alfama-tile-coasters", "azul", 1)]),
    ):
        subtotal = sum(i["price"] * i["qty"] for i in items)
        shipping = 0 if subtotal >= catalog.FREE_OVER else catalog.DELIVERY["postnord"]["price"]
        out.append({"number": number, "placed": placed, "delivered": delivered, "items": items,
                    "subtotal": subtotal, "shipping": shipping, "total": subtotal + shipping,
                    "delivery": "postnord", "email": m["email"], "first": m["first"], "phone": m["phone"],
                    "address": addr, "brand": "Visa", "last4": "4242"})
    return out


SEEDED = {o["number"]: o for o in _seeded()}


# ------------------------------------------------------------------ helpers

def _business_days(start, n):
    d = start
    while n > 0:
        d += datetime.timedelta(days=1)
        if d.weekday() < 5:
            n -= 1
    return d


def _brand(digits):
    if digits.startswith("4"):
        return "Visa"
    if re.match(r"^(5[1-5]|2[2-7])", digits):
        return "Mastercard"
    if re.match(r"^3[47]", digits):
        return "American Express"
    return "Card"


def _luhn(digits):
    total = 0
    for i, ch in enumerate(reversed(digits)):
        n = int(ch)
        if i % 2:
            n *= 2
            if n > 9:
                n -= 9
        total += n
    return total % 10 == 0


def _bag(raw):
    try:
        lines = json.loads(raw or "[]")
    except ValueError:
        lines = []
    items = []
    for line in lines if isinstance(lines, list) else []:
        try:
            slug, color, qty = line.get("slug"), line.get("color"), int(line.get("qty", 1))
        except (AttributeError, TypeError, ValueError):
            continue
        if slug in catalog.BY_SLUG and 0 < qty <= 20:
            items.append(_item(slug, color, qty))
    return items


def _validate(f):
    errors = {}
    email = f.get("email", "").strip()
    if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
        errors["email"] = "Enter an email address, like name@example.com."
    for key, say in (("name", "Enter your full name."), ("address1", "Enter your street address."),
                     ("city", "Enter your city."), ("ccname", "Enter the name on your card.")):
        if not f.get(key, "").strip():
            errors[key] = say
    if len(re.sub(r"\D", "", f.get("postal_code", ""))) < 4:
        errors["postal_code"] = "Enter a postal code, like 116 40."
    if len(re.sub(r"\D", "", f.get("phone", ""))) < 7:
        errors["phone"] = "Enter a phone number for delivery updates."
    digits = re.sub(r"\D", "", f.get("cardnumber", ""))
    if not (12 <= len(digits) <= 19) or not _luhn(digits):
        errors["cardnumber"] = "Your card number is incomplete or not valid."
    m = re.match(r"^\s*(\d{1,2})\s*/?\s*(\d{2}|\d{4})\s*$", f.get("exp", ""))
    if not m or not 1 <= int(m.group(1)) <= 12:
        errors["exp"] = "Enter the expiration date as MM / YY."
    else:
        year = int(m.group(2)) % 100 + 2000
        today = datetime.date.today()
        if (year, int(m.group(1))) < (today.year, today.month):
            errors["exp"] = "Your card has expired."
    if not re.match(r"^\d{3,4}$", f.get("cvc", "").strip()):
        errors["cvc"] = "Enter the 3 or 4 digit security code."
    return errors


def _place(f, items):
    now = datetime.datetime.now()
    method = f.get("delivery") if f.get("delivery") in catalog.DELIVERY else "postnord"
    subtotal = sum(i["price"] * i["qty"] for i in items)
    if method == "postnord":
        shipping = 0 if subtotal >= catalog.FREE_OVER else catalog.DELIVERY["postnord"]["price"]
        first, last = _business_days(now.date(), 2), _business_days(now.date(), 4)
        eta = "Arriving between %s and %s" % (pages.day(first), pages.day(last))
        eta_short = "%s %d to %d" % (first.strftime("%b"), first.day, last.day) if first.month == last.month else \
            "%s to %s" % (first.strftime("%b %d"), last.strftime("%b %d"))
    else:
        shipping = catalog.DELIVERY["budbee"]["price"]
        tomorrow = now.date() + datetime.timedelta(days=1)
        eta = "Arriving tomorrow, %s, 17:00 to 22:00" % pages.day(tomorrow)
        eta_short = "tomorrow evening"
    digits = re.sub(r"\D", "", f.get("cardnumber", ""))
    country = dict(catalog.COUNTRIES).get(f.get("country", "SE"), "Sweden")
    name = f.get("name", "").strip()
    with LOCK:
        number = str(NEXT[0])
        NEXT[0] += 7
        order = {
            "number": number, "placed": now, "items": items, "subtotal": subtotal, "shipping": shipping,
            "total": subtotal + shipping, "delivery": method, "email": f.get("email", "").strip(),
            "first": name.split(" ")[0] if name else "there", "phone": f.get("phone", "").strip(),
            "address": {"name": name, "line1": f.get("address1", "").strip(), "line2": f.get("address2", "").strip(),
                        "postal": f.get("postal_code", "").strip(), "city": f.get("city", "").strip(), "country": country},
            "brand": _brand(digits), "last4": digits[-4:], "eta": eta, "eta_short": eta_short,
        }
        ORDERS[number] = order
    return order


def _media(ctx, name):
    if name not in MEDIA:
        m = re.match(r"^([a-z0-9-]+?)(?:-([a-z]+))?(?:-(detail|dims))?\.svg$", name)
        svg = None
        if name == "hero.svg":
            svg = art.hero()
        elif name == "story.svg":
            svg = art.story()
        elif name.startswith("collection-"):
            key = name[len("collection-"):-4]
            if key in ("living", "kitchen", "textiles"):
                svg = art.collection(key)
        elif m:
            slug, color, view = m.group(1), m.group(2), m.group(3) or "hero"
            if slug not in catalog.BY_SLUG and color:
                # the slug's own last word was taken for a color
                slug, color = slug + "-" + color, None
            if slug in catalog.BY_SLUG:
                p = catalog.BY_SLUG[slug]
                keys = [c[0] for c in p["colors"]]
                if view == "dims" or color in keys or color is None:
                    svg = art.product(slug, color if color in keys else keys[0], view)
        if svg is None:
            return None
        MEDIA[name] = svg.encode("utf-8")
    return ctx.html(MEDIA[name], 200, {"Content-Type": "image/svg+xml; charset=utf-8",
                                        "Cache-Control": "public, max-age=3600"})


def _send_pdf(ctx, data, filename):
    """A PDF as an attachment, sent at RATE: ctx.file reads it at once, so
    the file on disk lives only as long as this call."""
    TMP.mkdir(parents=True, exist_ok=True)
    path = TMP / ("%s-%s" % (uuid.uuid4().hex[:8], re.sub(r"[^A-Za-z0-9.-]+", "-", filename)))
    path.write_bytes(data)
    try:
        return ctx.file(path, download=filename, rate=RATE, kind="application/pdf")
    finally:
        path.unlink(missing_ok=True)


# ------------------------------------------------------------------ the PDFs

INK = (0.12, 0.11, 0.10)
MUTED = (0.42, 0.39, 0.35)
LINE = (0.86, 0.83, 0.78)
SAND = (0.96, 0.94, 0.91)


def _letterhead(pg, right_title):
    W, H = pdf.A4
    pg.box(0, H - 8, W, 8, (0.17, 0.16, 0.15))
    # the mark: a needle pointing north
    cx, cy = 62, H - 70
    pg.path([(cx, cy + 13), (cx + 4.4, cy - 1.5), (cx, cy + 1), (cx - 4.4, cy - 1.5)], (0.17, 0.16, 0.15))
    pg.path([(cx - 4.4, cy - 1.5), (cx, cy + 1), (cx + 4.4, cy - 1.5), (cx, cy - 13)], (0.79, 0.69, 0.54))
    pg.text(80, H - 78, "Nordbutik", 24, "F3", INK)
    pg.text(W - 50, H - 76, right_title, 20, "F1", INK, "right")
    pg.text(50, H - 104, "Nordbutik AB · Krukmakargatan 21 · 118 51 Stockholm · Sweden", 8.5, "F1", MUTED)


def invoice_pdf(o):
    W, H = pdf.A4
    pg = pdf.Page()
    _letterhead(pg, "Invoice")
    y = H - 150
    meta = [("Invoice number", "INV-%s" % o["number"]), ("Order", "#%s" % o["number"]),
            ("Invoice date", pages.date_long(o["placed"])), ("Paid", pages.date_long(o["placed"]))]
    for i, (k, v) in enumerate(meta):
        pg.text(W - 210, y - i * 15, k, 8.5, "F1", MUTED)
        pg.text(W - 50, y - i * 15, v, 8.5, "F2", INK, "right")
    a = o["address"]
    pg.text(50, y, "BILLED TO", 7.5, "F2", MUTED, spacing=0.8)
    for i, line in enumerate([a["name"], o["email"]]):
        pg.text(50, y - 16 - i * 13, line, 9.5, "F1", INK)
    pg.text(190, y, "DELIVERED TO", 7.5, "F2", MUTED, spacing=0.8)
    lines = [a["name"], a["line1"]] + ([a["line2"]] if a.get("line2") else []) + ["%s %s" % (a["postal"], a["city"]), a["country"]]
    for i, line in enumerate(lines):
        pg.text(190, y - 16 - i * 13, line, 9.5, "F1", INK)
    y -= 110
    pg.box(50, y - 6, W - 100, 22, SAND)
    cols = [(60, "Item", "left"), (300, "Color", "left"), (400, "Qty", "right"), (470, "Price", "right"), (W - 60, "Amount", "right")]
    for x, label, al in cols:
        pg.text(x, y + 1, label, 8.5, "F2", INK, al)
    y -= 28
    for it in o["items"]:
        pg.text(60, y, it["name"], 9.5, "F1", INK)
        pg.text(300, y, it["color_name"], 9.5, "F1", MUTED)
        pg.text(400, y, str(it["qty"]), 9.5, "F1", INK, "right")
        pg.text(470, y, pages.kr(it["price"]), 9.5, "F1", INK, "right")
        pg.text(W - 60, y, pages.kr(it["price"] * it["qty"]), 9.5, "F1", INK, "right")
        y -= 10
        pg.line(50, y, W - 50, y, 0.5, LINE)
        y -= 18
    y -= 6
    method = catalog.DELIVERY[o["delivery"]]["name"]
    totals = [("Subtotal", pages.kr(o["subtotal"])),
              ("Delivery (%s)" % method, "Free" if o["shipping"] == 0 else pages.kr(o["shipping"])),
              ("Of which VAT 25%", pages.kr2(o["total"] * 0.2))]
    for k, v in totals:
        pg.text(340, y, k, 9.5, "F1", MUTED)
        pg.text(W - 60, y, v, 9.5, "F1", INK, "right")
        y -= 17
    y -= 4
    pg.line(340, y + 10, W - 50, y + 10, 0.8, INK)
    pg.text(340, y - 6, "Total paid", 11, "F2", INK)
    pg.text(W - 60, y - 6, "SEK " + pages.kr(o["total"]), 11, "F2", INK, "right")
    y -= 50
    pg.text(50, y, "Paid with %s ending in %s on %s." % (o["brand"], o["last4"], pages.date_long(o["placed"])), 9.5, "F1", INK)
    pg.text(50, y - 15, "Questions about this invoice? Reply to your order confirmation and we will help.", 9.5, "F1", MUTED)
    pg.text(50, y - 30, "You can return anything within 30 days, free of charge, from any PostNord service point.", 9.5, "F1", MUTED)
    pg.line(50, 70, W - 50, 70, 0.5, LINE)
    pg.text(50, 54, "Nordbutik AB · Registered in Stockholm, Sweden · Thank you for shopping slowly.", 8, "F1", MUTED)
    pg.text(W - 50, 54, "Page 1 of 1", 8, "F1", MUTED, "right")
    return pdf.document([pg], "Nordbutik invoice %s" % o["number"], PDF_SIZE)


def care_pdf(p):
    W, H = pdf.A4
    pg = pdf.Page()
    _letterhead(pg, "Care guide")
    y = H - 160
    pg.text(50, y, p["name"], 26, "F3", INK)
    pg.text(50, y - 22, "%s · %s" % (p["made"], ", ".join(c[1] for c in p["colors"])), 9.5, "F1", MUTED)
    y -= 60
    pg.text(50, y, p["blurb"], 10.5, "F1", INK)
    y -= 40
    sections = [("WHAT IT IS", p["details"]), ("EVERY DAY", p["care"]),
                ("NOW AND THEN", ["Air it out by an open window on a dry day", "Store it clean, dry and folded, away from strong sun",
                                  "Small slubs in the weave are part of linen and wool"] if "textiles" in p["collections"] else
                 ["Store it clean and dry, away from strong sun", "Use it every day: that is what it was made for",
                  "Small marks and variations come from being made by hand"]),
                ("IF SOMETHING HAPPENS", ["Blot, don't rub, and use cold water first",
                                          "Write to us with a picture: we know our makers and can usually help",
                                          "Repairs and spare parts are on us for the first two years"])]
    for title, items in sections:
        pg.text(50, y, title, 8, "F2", MUTED, spacing=1)
        y -= 20
        for it in items:
            pg.box(52, y + 3, 3, 3, (0.79, 0.69, 0.54))
            pg.text(64, y, it, 10, "F1", INK)
            y -= 17
        y -= 16
    pg.line(50, 70, W - 50, 70, 0.5, LINE)
    pg.text(50, 54, "Nordbutik AB · Krukmakargatan 21 · 118 51 Stockholm · Keep this guide for later.", 8, "F1", MUTED)
    pg.text(W - 50, 54, "Page 1 of 1", 8, "F1", MUTED, "right")
    return pdf.document([pg], "Care guide, %s" % p["name"], PDF_SIZE)


# ------------------------------------------------------------------ routes

def _order(number):
    return ORDERS.get(number) or SEEDED.get(number)


def handle(req, ctx):
    path = req.path.rstrip("/") or "/"
    if path.endswith(".py") or path in ("/site.json",) or "__pycache__" in path:
        return ctx.html(pages.not_found(), 404)
    if path.startswith("/assets/") or path in ("/favicon.svg", "/favicon.png", "/apple-touch-icon.png", "/favicon.ico"):
        if path == "/favicon.ico":
            return ctx.file(HERE / "favicon.png", kind="image/png")
        return None
    if path.startswith("/media/"):
        reply = _media(ctx, path[len("/media/"):])
        return reply if reply else ctx.html(pages.not_found(), 404)

    if path == "/":
        return ctx.html(pages.home())
    if path == "/collections":
        return ctx.redirect("/collections/all")
    m = re.match(r"^/collections/([a-z-]+)$", path)
    if m:
        body = pages.collection(m.group(1))
        return ctx.html(body) if body else ctx.html(pages.not_found(), 404)
    if path == "/search":
        return ctx.html(pages.search(req.query.get("q", "").strip()))
    m = re.match(r"^/p/([a-z0-9-]+)/care-guide\.pdf$", path)
    if m and m.group(1) in catalog.BY_SLUG:
        p = catalog.BY_SLUG[m.group(1)]
        return _send_pdf(ctx, care_pdf(p), "Nordbutik care guide, %s.pdf" % p["name"])
    m = re.match(r"^/p/([a-z0-9-]+)$", path)
    if m:
        body = pages.product(m.group(1))
        return ctx.html(body) if body else ctx.html(pages.not_found(), 404)
    if path == "/bag":
        return ctx.html(pages.bag())
    if path == "/checkout":
        if req.method == "POST":
            return _checkout(req, ctx)
        return ctx.html(pages.checkout())
    m = re.match(r"^/order/(\d+)$", path)
    if m:
        o = _order(m.group(1))
        if not o:
            return ctx.html(pages.not_found(), 404)
        fresh = req.cookies.get("nb_placed") == o["number"] or (o["number"] in ORDERS and not o.get("delivered"))
        return ctx.html(pages.order_page(o, fresh=fresh and "delivered" not in o))
    if path in ("/account", "/account/login"):
        return ctx.redirect("/account/orders")
    if path == "/account/orders":
        mine = sorted(ORDERS.values(), key=lambda o: o["placed"], reverse=True) + list(SEEDED.values())
        return ctx.html(pages.orders_page(mine))
    m = re.match(r"^/account/orders/(\d+)/invoice\.pdf$", path)
    if m:
        o = _order(m.group(1))
        if not o:
            return ctx.html(pages.not_found(), 404)
        return _send_pdf(ctx, invoice_pdf(o), "Nordbutik invoice %s.pdf" % o["number"])
    m = re.match(r"^/account/orders/(\d+)$", path)
    if m and _order(m.group(1)):
        return ctx.redirect("/order/%s" % m.group(1))
    if path == "/account/addresses":
        return ctx.html(pages.addresses_page())
    if path == "/account/profile":
        return ctx.html(pages.profile_page())
    if path == "/help":
        return ctx.html(pages.help_page())
    if path == "/about":
        return ctx.html(pages.about_page())
    return ctx.html(pages.not_found(), 404)


def _checkout(req, ctx):
    f = req.form
    items = _bag(f.get("bag"))
    if not items:
        return ctx.redirect("/bag")
    errors = _validate(f)
    if errors:
        keep = {k: v for k, v in f.items() if k not in ("cvc",)}
        return ctx.html(pages.checkout(keep, errors), 422)
    order = _place(f, items)
    return ctx.redirect("/order/%s" % order["number"], cookies="nb_placed=%s; Path=/; Max-Age=600; SameSite=Lax" % order["number"])
