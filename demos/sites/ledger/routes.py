"""Ledger: what its static pages can't do on their own.

    GET  /invoices/<number>.pdf        the invoice as a real PDF, about 2 MB,
                                       sent as an attachment at ~900 KB/s
    GET  /reports/<report>.csv         a few hundred rows of CSV, sent slowly
    POST /expenses                     a new expense, receipts and all
                                       (multipart/form-data), then the list
    GET  /api/expenses                 expenses added since the server started
    GET  /expenses/<id>/receipts/<n>   a receipt as it was uploaded
    POST /payments/<id>/retry          the failed payment, retried: it succeeds
"""
import json
import random
import re
import string
import threading
import time

PDF_RATE = 900_000
PDF_SIZE = 2_000_000
CSV_SECONDS = 2.2

LOCK = threading.Lock()
EXPENSES = []
RECEIPTS = {}
RECEIPT_BUDGET = 40 * 1024 * 1024


# ---------------------------------------------------------------- the books

SELLER = ["Tern Labs AB", "Hornsgatan 45", "118 49 Stockholm", "Sweden", "billing@ternlabs.com", "VAT SE559312874401"]

CUSTOMERS = {
    "northwind": ("Northwind Studio AB", "billing@northwind.io", ["Linn\u00e9gatan 18", "114 47 Stockholm", "Sweden"]),
    "vesper": ("Vesper Hotels Group", "accounts@vesperhotels.com", ["88 Lafayette Street", "New York, NY 10013", "United States"]),
    "fjell": ("Fjell Studio AS", "finance@fjellstudio.no", ["Bryggen 14", "5003 Bergen", "Norway"]),
    "copperleaf": ("Copperleaf Ltd", "ap@copperleaf.io", ["18 Clerkenwell Road", "London EC1M 5RN", "United Kingdom"]),
    "brightline": ("Brightline Health GmbH", "accounts@brightline.health", ["Torstra\u00dfe 140", "10119 Berlin", "Germany"]),
    "kestrel": ("Kestrel Health AB", "ap@kestrelhealth.se", ["Kungsgatan 37", "111 56 Stockholm", "Sweden"]),
    "kitewing": ("Kitewing Robotics, Inc.", "finance@kitewing.dev", ["455 Grand Street", "Brooklyn, NY 11211", "United States"]),
    "oakridge": ("Oakridge & Co LLC", "finance@oakridgeco.com", ["410 Congress Avenue", "Austin, TX 78701", "United States"]),
    "saltmarsh": ("Saltmarsh Coffee Co.", "hello@saltmarsh.coffee", ["21 Water Street", "Portland, ME 04101", "United States"]),
    "arbor": ("Arbor Legal LLP", "billing@arborlegal.co.uk", ["5 New Street Square", "London EC4A 3TW", "United Kingdom"]),
    "meridian": ("Meridian Freight Inc.", "invoices@meridianfreight.com", ["900 Commerce Drive", "Oak Brook, IL 60523", "United States"]),
    "pinecrest": ("Pinecrest Schools", "it@pinecrest.edu", ["300 Pinecrest Road", "Durham, NC 27705", "United States"]),
    "mosaic": ("Mosaic Learning Foundation", "finance@mosaiclearning.org", ["1550 Market Street", "Denver, CO 80202", "United States"]),
    "nordlys": ("Nordlys Media AS", "finance@nordlys.media", ["Storgata 8", "9008 Troms\u00f8", "Norway"]),
    "bluefin": ("Bluefin Logistics B.V.", "ap@bluefinlogistics.com", ["Wilhelminakade 91", "3072 AP Rotterdam", "Netherlands"]),
    "fernway": ("Fernway, Inc.", "billing@fernway.app", ["2100 Folsom Street", "San Francisco, CA 94110", "United States"]),
    "quarry": ("Quarry Design ApS", "studio@quarry.design", ["J\u00e6gersborggade 12", "2200 Copenhagen N", "Denmark"]),
    "halcyon": ("Halcyon Labs, Inc.", "billing@halcyonlabs.ai", ["77 Middlefield Road", "Palo Alto, CA 94301", "United States"]),
    "ember": ("Ember & Oak", "hello@emberandoak.com", ["77 Main Street", "Burlington, VT 05401", "United States"]),
}

# Each invoice: customer, lines (name, term, quantity, unit price), VAT rate,
# status, created and due as days from today (due None for none).
def _seats(c, plan, seats, status, created, due):
    unit = {"Starter": 8, "Team": 12, "Business": 20}[plan]
    return dict(c=c, lines=[("Tern %s" % plan, "monthly", seats, unit)], vat=0, status=status, created=created, due=due)


INVOICES = {
    "INV-2026-0944": _seats("bluefin", "Team", 36, "Draft", 0, 30),
    "INV-2026-0943": _seats("fernway", "Team", 28, "Draft", 0, 30),
    "INV-2026-0942": _seats("vesper", "Business", 150, "Paid", 0, 0),
    "INV-2026-0941": dict(c="northwind", lines=[("Focus insights add-on", "annual", 1, 192)], vat=0.25, status="Past due", created=0, due=0),
    "INV-2026-0940": _seats("fjell", "Business", 45, "Paid", 0, 0),
    "INV-2026-0939": _seats("copperleaf", "Team", 32, "Paid", 0, 0),
    "INV-2026-0938": _seats("kestrel", "Business", 85, "Open", 0, 7),
    "INV-2026-0937": _seats("brightline", "Business", 120, "Paid", 0, 0),
    "INV-2026-0936": _seats("kitewing", "Business", 40, "Paid", 0, 0),
    "INV-2026-0935": _seats("oakridge", "Business", 60, "Paid", -1, -1),
    "INV-2026-0934": _seats("saltmarsh", "Starter", 6, "Paid", -1, -1),
    "INV-2026-0933": _seats("meridian", "Team", 40, "Paid", -1, -1),
    "INV-2026-0932": dict(c="pinecrest", lines=[("Tern Starter seat", "annual", 25, 96)], vat=0, status="Open", created=-2, due=28),
    "INV-2026-0931": _seats("mosaic", "Business", 70, "Paid", -2, -2),
    "INV-2026-0929": _seats("arbor", "Team", 14, "Past due", -9, -9),
    "INV-2026-0926": _seats("nordlys", "Team", 22, "Past due", -16, -16),
    "INV-2026-0921": _seats("quarry", "Team", 9, "Past due", -21, -21),
    "INV-2026-0918": dict(c="northwind", lines=[("Tern Team seat", "annual", 12, 96), ("Focus insights add-on", None, 1, 240),
                                               ("Onboarding workshop", None, 1, 400)], vat=0.25, status="Open", created=-12, due=2),
    "INV-2026-0915": _seats("ember", "Starter", 4, "Void", -15, None),
}


def day(offset, base=None):
    t = (base or time.time()) + offset * 86400
    return time.localtime(t)


def long_date(t):
    return time.strftime("%B ", t) + str(t.tm_mday) + time.strftime(", %Y", t)


def money(n):
    return "${:,.2f}".format(n)


# ---------------------------------------------------------------- a small PDF writer

HELVETICA = {
    " ": 278, "!": 278, '"': 355, "#": 556, "$": 556, "%": 889, "&": 667, "'": 191, "(": 333, ")": 333, "*": 389,
    "+": 584, ",": 278, "-": 333, ".": 278, "/": 278, ":": 278, ";": 278, "<": 584, "=": 584, ">": 584, "?": 556,
    "@": 1015, "A": 667, "B": 667, "C": 722, "D": 722, "E": 667, "F": 611, "G": 778, "H": 722, "I": 278, "J": 500,
    "K": 667, "L": 556, "M": 833, "N": 722, "O": 778, "P": 667, "Q": 778, "R": 722, "S": 667, "T": 611, "U": 722,
    "V": 667, "W": 944, "X": 667, "Y": 667, "Z": 611, "[": 278, "\\": 278, "]": 278, "^": 469, "_": 556, "`": 333,
    "a": 556, "b": 556, "c": 500, "d": 556, "e": 556, "f": 278, "g": 556, "h": 556, "i": 222, "j": 222, "k": 500,
    "l": 222, "m": 833, "n": 556, "o": 556, "p": 556, "q": 556, "r": 333, "s": 500, "t": 278, "u": 556, "v": 500,
    "w": 722, "x": 500, "y": 500, "z": 500, "{": 334, "|": 260, "}": 334, "~": 584, "·": 278, "•": 350,
}
HELVETICA_BOLD = dict(HELVETICA, **{
    "!": 333, '"': 474, "&": 722, "'": 238, ":": 333, ";": 333, "?": 611, "@": 975, "A": 722, "B": 722, "J": 556,
    "K": 722, "L": 611, "[": 333, "]": 333, "^": 584, "b": 611, "c": 556, "d": 611, "f": 333, "g": 611, "h": 611,
    "i": 278, "j": 278, "k": 556, "l": 278, "m": 889, "n": 611, "o": 611, "p": 611, "q": 611, "r": 389, "s": 556,
    "t": 333, "u": 611, "v": 556, "w": 778, "x": 556, "y": 556, "{": 389, "|": 280, "}": 389,
})
for _d in "0123456789":
    HELVETICA[_d] = HELVETICA_BOLD[_d] = 556


def width(text, size, bold=False):
    table = HELVETICA_BOLD if bold else HELVETICA
    return sum(table.get(ch, 556) for ch in text) * size / 1000.0


def pdf_string(text):
    raw = text.encode("cp1252", "replace")
    return b"(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)") + b")"


def rgb(hex_color):
    h = hex_color.lstrip("#")
    return " ".join("%.3f" % (int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


class Page:
    def __init__(self):
        self.ops = []

    def text(self, x, y, text, size=10, bold=False, color="#1a1f36", align="left"):
        if align == "right":
            x -= width(text, size, bold)
        elif align == "center":
            x -= width(text, size, bold) / 2
        self.ops.append(b"BT /%s %.2f Tf %s rg %.2f %.2f Td " % (b"F2" if bold else b"F1", size, rgb(color).encode(), x, y)
                        + pdf_string(text) + b" Tj ET")

    def rect(self, x, y, w, h, color):
        self.ops.append(("%s rg %.2f %.2f %.2f %.2f re f" % (rgb(color), x, y, w, h)).encode())

    def line(self, x1, y1, x2, y2, color="#e3e8ee", w=0.75):
        self.ops.append(("%s RG %.2f w %.2f %.2f m %.2f %.2f l S" % (rgb(color), w, x1, y1, x2, y2)).encode())

    def rounded(self, x, y, w, h, r, color):
        k = 0.5523 * r
        p = [
            "%.2f %.2f m" % (x + r, y),
            "%.2f %.2f l" % (x + w - r, y),
            "%.2f %.2f %.2f %.2f %.2f %.2f c" % (x + w - r + k, y, x + w, y + r - k, x + w, y + r),
            "%.2f %.2f l" % (x + w, y + h - r),
            "%.2f %.2f %.2f %.2f %.2f %.2f c" % (x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h),
            "%.2f %.2f l" % (x + r, y + h),
            "%.2f %.2f %.2f %.2f %.2f %.2f c" % (x + r - k, y + h, x, y + h - r + k, x, y + h - r),
            "%.2f %.2f l" % (x, y + r),
            "%.2f %.2f %.2f %.2f %.2f %.2f c" % (x, y + r - k, x + r - k, y, x + r, y),
        ]
        self.ops.append(("%s rg " % rgb(color) + " ".join(p) + " h f").encode())

    def stroke_path(self, points, color="#ffffff", w=2.0):
        p = ["%.2f %.2f m" % points[0]] + ["%.2f %.2f l" % pt for pt in points[1:]]
        self.ops.append(("%s RG %.2f w 1 J 1 j " % (rgb(color), w) + " ".join(p) + " S").encode())

    def bytes(self):
        return b"\n".join(self.ops)


def build_pdf(page, title, pad_to=0):
    objs = []

    def add(body):
        objs.append(body)
        return len(objs)

    content = page.bytes()
    catalog = add(b"")  # filled below
    pages = add(b"")
    f1 = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    f2 = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    stream = add(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
    page_obj = add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> /Contents %d 0 R >>"
                   % (pages, f1, f2, stream))
    objs[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % pages
    objs[pages - 1] = b"<< /Type /Pages /Kids [%d 0 R] /Count 1 >>" % page_obj
    stamp = time.strftime("D:%Y%m%d%H%M%S")
    info = add(b"<< /Title " + pdf_string(title) + b" /Author (Tern Labs AB) /Producer (Ledger Billing) /Creator (Ledger) /CreationDate (" + stamp.encode() + b") >>")
    if pad_to:
        # The archived copy carries an embedded, unreferenced resource block,
        # which is what makes a Ledger PDF the size it is.
        filler = random.Random(title).randbytes(max(0, pad_to - 6000))
        add(b"<< /Length %d /Type /EmbeddedFile /Subtype /application#2Foctet-stream >>\nstream\n" % len(filler) + filler + b"\nendstream")

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, catalog, info, xref)
    return bytes(out)


def tern_mark(page, x, y, s):
    """Tern's own mark, as its brand kit draws it: a white wing on Tern's blue."""
    page.rounded(x, y, s, s, s * 0.25, "#3b4bd8")
    u = s / 64.0
    # The kit's path, M14 38 c8-14 22-20 36-16 -10 2-18 8-22 18, flipped for PDF space.
    page.ops.append(("1 1 1 RG %.2f w 1 J 1 j %.2f %.2f m %.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c S" % (
        5 * u,
        x + 14 * u, y + (64 - 38) * u,
        x + 22 * u, y + (64 - 24) * u, x + 36 * u, y + (64 - 18) * u, x + 50 * u, y + (64 - 22) * u,
        x + 40 * u, y + (64 - 24) * u, x + 32 * u, y + (64 - 30) * u, x + 28 * u, y + (64 - 40) * u)).encode())


def invoice_pdf(number):
    info = INVOICES.get(number) or _seats("northwind", "Team", 12, "Open", 0, 14)
    name, email, address = CUSTOMERS.get(info["c"], CUSTOMERS["northwind"])
    created = day(info["created"])
    due = day(info["due"]) if info["due"] is not None else None
    status = info["status"]
    subtotal = sum(q * unit for _, _, q, unit in info["lines"])
    vat = round(subtotal * info["vat"], 2)
    amount = subtotal + vat
    paid = status == "Paid"

    p = Page()
    ink, ink2, ink3, line = "#1a1f36", "#414552", "#6a7383", "#e3e8ee"
    left, right = 54, 558

    # Masthead: the invoice is Tern's, Ledger only prints it.
    p.text(left, 716, "Invoice", 24, True, ink)
    tern_mark(p, right - 30, 708, 30)
    p.text(right - 38, 721, "Tern Labs", 13, True, ink, align="right")
    p.text(right - 38, 709, "calm scheduling for teams", 8, False, ink3, align="right")

    rows = [("Invoice number", number), ("Date of issue", long_date(created))]
    if due:
        rows.append(("Date due", long_date(due)))
    yy = 684
    for k, v in rows:
        p.text(left, yy, k, 9.5, True, ink2)
        p.text(left + 92, yy, v, 9.5, False, ink)
        yy -= 14

    # Parties
    yy = 616
    p.text(left, yy, SELLER[0], 9.5, True, ink)
    for i, row in enumerate(SELLER[1:]):
        p.text(left, yy - 13 * (i + 1), row, 9.5, False, ink2)
    bx = 250
    p.text(bx, yy, "Bill to", 9.5, True, ink)
    for i, row in enumerate([name] + address + [email]):
        p.text(bx, yy - 13 * (i + 1), row, 9.5, False, ink2)

    # The amount
    yy = 520
    if paid:
        headline = "%s paid on %s" % (money(amount), long_date(created))
    elif status == "Void":
        headline = "%s, void" % money(amount)
    elif due:
        headline = "%s due %s" % (money(amount), long_date(due))
    else:
        headline = money(amount)
    p.text(left, yy, headline, 15, True, ink)
    if not paid and status != "Void":
        p.text(left, yy - 18, "Pay online at ledger.localtest.me/pay/" + number, 9.5, False, "#0e756d")
    stamp = {"Paid": ("PAID", "#e2f5e9", "#137a43"), "Past due": ("PAST DUE", "#fdecea", "#b42318"),
             "Void": ("VOID", "#edf0f3", "#4a5662"), "Draft": ("DRAFT", "#edf0f3", "#4a5662")}.get(status)
    if stamp:
        w = width(stamp[0], 9.5, True) + 28
        p.rounded(right - w, yy - 4, w, 20, 5, stamp[1])
        p.text(right - w / 2, yy + 2, stamp[0], 9.5, True, stamp[2], align="center")

    # Line items
    yy = 452
    for x, label, align in [(left, "Description", "left"), (370, "Qty", "right"), (462, "Unit price", "right"), (right, "Amount", "right")]:
        p.text(x, yy, label, 9, True, ink3, align=align)
    p.line(left, yy - 8, right, yy - 8, line, 0.9)
    yy -= 28
    for title, term, qty, unit in info["lines"]:
        if term == "monthly":
            end = day(info["created"] + 30)
            sub = "%s to %s" % (time.strftime("%b ", created) + str(created.tm_mday),
                                time.strftime("%b ", end) + str(end.tm_mday) + time.strftime(", %Y", end))
        elif term == "annual":
            sub = "Annual, 12 months from %s" % long_date(created)
        else:
            sub = None
        p.text(left, yy, title, 10, True, ink)
        if sub:
            p.text(left, yy - 13, sub, 9, False, ink3)
        p.text(370, yy, str(qty), 10, False, ink, align="right")
        p.text(462, yy, money(unit), 10, False, ink, align="right")
        p.text(right, yy, money(qty * unit), 10, False, ink, align="right")
        yy -= 34 if sub else 26
    p.line(left, yy + 10, right, yy + 10, line, 0.75)

    # Totals
    yy -= 8
    if info["vat"]:
        tax = ("VAT %d%%" % round(info["vat"] * 100), money(vat))
    elif address[-1] == "United States":
        tax = ("Tax (0%)", money(0))
    else:
        tax = ("Tax (0%, reverse charge)", money(0))
    totals = [("Subtotal", money(subtotal), False), (tax[0], tax[1], False), ("Total", money(amount), False)]
    if paid:
        totals += [("Amount paid", money(amount), False), ("Amount due", money(0), True)]
    elif status == "Void":
        totals += [("Amount due", money(0), True)]
    else:
        totals += [("Amount due", money(amount), True)]
    for label, value, strong in totals:
        p.text(330, yy, label, 10, strong, ink if strong else ink2)
        p.text(right, yy, value, 10, strong, ink, align="right")
        p.line(330, yy - 8, right, yy - 8, line, 0.6)
        yy -= 22

    # Notes
    yy -= 18
    p.text(left, yy, "Thank you for choosing Tern. Seats are prorated to the day when your team grows or shrinks.", 9, False, ink2)
    p.text(left, yy - 13, "Questions about this invoice? Write to billing@ternlabs.com and quote " + number + ".", 9, False, ink2)
    if not paid and status != "Void":
        p.text(left, yy - 26, "Bank transfer: Tern Labs AB, IBAN SE45 5000 0000 0583 9825 7466, reference " + number + ".", 9, False, ink2)

    # Footer
    p.line(left, 64, right, 64, line, 0.75)
    p.text(left, 48, "%s · %s" % (number, headline), 8.5, False, ink3)
    p.text(right, 48, "Page 1 of 1", 8.5, False, ink3, align="right")
    p.text(left, 36, "Issued by Tern Labs AB through Ledger", 8.5, False, ink3)

    return build_pdf(p, "Invoice %s" % number, pad_to=PDF_SIZE)


# ---------------------------------------------------------------- CSV

def report_csv(report):
    rng = random.Random(report)
    names = [(v[0], v[1]) for v in CUSTOMERS.values()]
    plans = [("Tern Team", 12), ("Tern Business", 20), ("Tern Starter", 8)]
    now = time.time()
    lines = []
    if report.startswith("mrr"):
        lines.append("month,starting_mrr,new,expansion,contraction,churned,ending_mrr,subscriptions")
        mrr = 17240.0
        subs = 512
        for i in range(24):
            t = time.localtime(now - (23 - i) * 30.4 * 86400)
            new = round(mrr * rng.uniform(0.045, 0.07), 2)
            exp = round(mrr * rng.uniform(0.02, 0.035), 2)
            con = round(mrr * rng.uniform(0.003, 0.008), 2)
            chu = round(mrr * rng.uniform(0.012, 0.02), 2)
            end = mrr + new + exp - con - chu
            subs += rng.randint(18, 52)
            lines.append("%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d" % (time.strftime("%Y-%m", t), mrr, new, exp, con, chu, end, subs))
            mrr = end
        # Pad with the per-customer movements behind the months.
        lines.append("")
        lines.append("customer,email,month,movement,amount")
        for i in range(380):
            name, email = rng.choice(names)
            t = time.localtime(now - rng.randint(0, 700) * 86400)
            kind = rng.choice(["new", "expansion", "expansion", "contraction", "churned"])
            lines.append('"%s",%s,%s,%s,%.2f' % (name, email, time.strftime("%Y-%m", t), kind, rng.choice([12, 24, 36, 48, 60, 96, 120, 240]) * (1 if kind in ("new", "expansion") else -1)))
    elif report.startswith("invoices"):
        lines.append("number,customer,customer_email,amount,currency,status,created,due")
        for number, info in sorted(INVOICES.items(), reverse=True):
            name, email, _ = CUSTOMERS[info["c"]]
            total = sum(q * u for _, _, q, u in info["lines"]) * (1 + info["vat"])
            lines.append('%s,"%s",%s,%.2f,usd,%s,%s,%s' % (number, name, email, total, info["status"].lower().replace(" ", "_"),
                                                        time.strftime("%Y-%m-%d", day(info["created"])),
                                                        time.strftime("%Y-%m-%d", day(info["due"])) if info["due"] is not None else ""))
        for i in range(914, 600, -1):
            name, email = rng.choice(names)
            amt = rng.choice([48, 108, 168, 216, 264, 336, 384, 432, 480, 900, 1200, 1400, 1700, 2400, 3000])
            t = day(-16 - (914 - i) // 3)
            lines.append('INV-2026-%04d,"%s",%s,%.2f,usd,%s,%s,%s' % (i, name, email, amt, rng.choices(["paid", "void"], [97, 3])[0],
                                                                   time.strftime("%Y-%m-%d", t), time.strftime("%Y-%m-%d", t)))
    elif report.startswith("customers"):
        lines.append("id,name,email,plan,seats,mrr,status,country,created")
        for i in range(412):
            name, email = names[i % len(names)] if i < len(names) else (
                "%s %s" % (rng.choice(["Aster", "Birch", "Cobalt", "Delta", "Elm", "Fjord", "Granite", "Harbor", "Iris", "Juniper", "Kelp", "Lumen",
                                        "Maple", "Nimbus", "Orchid", "Pine", "Quill", "Raven", "Sable", "Tide", "Umber", "Vale", "Willow"]),
                           rng.choice(["Studio", "Labs", "Health", "Partners", "Works", "Group", "Collective", "Systems", "Media", "Legal"])), None)
            if email is None:
                email = "billing@%s.com" % name.lower().replace(" ", "")
            plan, price = rng.choice(plans)
            seats = rng.randint(3, 160)
            lines.append('cus_%s,"%s",%s,%s,%d,%.2f,%s,%s,%s' % (
                "".join(rng.choice(string.ascii_letters + string.digits) for _ in range(14)), name, email, plan.replace("Tern ", ""), seats,
                seats * price, rng.choices(["active", "past_due", "trialing", "canceled"], [86, 4, 5, 5])[0],
                rng.choice(["US", "US", "US", "SE", "NO", "GB", "DE", "NL", "DK"]), time.strftime("%Y-%m-%d", day(-rng.randint(1, 760)))))
    elif report.startswith("expenses"):
        lines.append("date,merchant,category,spent_by,amount,currency,status,receipt")
        people = ["Mira Lindqvist", "Jonas Berg", "Anna Ek", "Elliot Park", "Sara Holm"]
        merchants = [("Northstack Cloud", "Software"), ("Tracklane", "Software"), ("Penline", "Software"), ("Bageri Petrus", "Meals"),
                     ("Taxi Kurir Stockholm", "Travel"), ("Officeland", "Hardware"), ("Fieldwork", "Research"), ("Typefoundry Co", "Software")]
        for i in range(160):
            merchant, cat = rng.choice(merchants)
            lines.append("%s,%s,%s,%s,%.2f,%s,%s,%s" % (time.strftime("%Y-%m-%d", day(-i // 2)), merchant, cat, rng.choice(people),
                                                     rng.uniform(40, 1400), rng.choice(["USD", "SEK", "EUR"]),
                                                     rng.choices(["approved", "reimbursed", "in_review", "needs_receipt"], [60, 25, 10, 5])[0],
                                                     rng.choice(["yes", "yes", "yes", "no"])))
    elif report.startswith("payouts"):
        lines.append("payout_id,arrival_date,amount,currency,status,destination,payments,refunds,fees")
        for i in range(420):
            t = time.localtime(now - i * 86400 * 0.5)
            amt = rng.uniform(6000, 24000)
            lines.append("po_1Q%s,%s,%.2f,usd,paid,Tern Labs AB 4417,%d,%d,%.2f" % (
                "".join(rng.choice(string.ascii_letters + string.digits) for _ in range(22)), time.strftime("%Y-%m-%d", t), amt,
                rng.randint(18, 90), rng.randint(0, 3), amt * 0.019))
    elif report.startswith("balance"):
        lines.append("created,type,description,amount,fee,net,currency,balance_after")
        bal = 61200.0
        for i in range(460):
            t = time.localtime(now - (460 - i) * 3300)
            kind = rng.choice(["charge"] * 6 + ["refund", "payout", "adjustment"])
            name, _ = rng.choice(names)
            amt = round(rng.choice([48, 108, 168, 216, 240, 264, 336, 384, 432, 480, 900, 1200, 1400, 1700, 2400, 3000]) * (1 if kind == "charge" else -1 if kind != "adjustment" else 0.1), 2)
            if kind == "payout":
                amt = -round(rng.uniform(8000, 22000), 2)
            fee = round(abs(amt) * 0.029 + 0.3, 2) if kind == "charge" else 0
            bal += amt - fee
            lines.append('%s,%s,"%s",%.2f,%.2f,%.2f,usd,%.2f' % (time.strftime("%Y-%m-%d %H:%M:%S", t), kind, name if kind != "payout" else "Payout to Tern Labs AB", amt, fee, amt - fee, bal))
    else:
        lines.append("id,created,customer,customer_email,description,amount,fee,net,currency,status,card_brand,card_last4")
        for i in range(480):
            t = time.localtime(now - i * 1500 - rng.randint(0, 900))
            name, email = rng.choice(names)
            plan, price = rng.choice(plans)
            seats = rng.randint(3, 150)
            amt = seats * price
            status = rng.choices(["succeeded", "failed", "refunded"], [93, 4, 3])[0]
            fee = round(amt * 0.029 + 0.3, 2) if status == "succeeded" else 0
            brand = rng.choice(["visa", "visa", "mastercard", "amex"])
            lines.append('py_3Q%s,%s,"%s",%s,"%s, %d seats",%.2f,%.2f,%.2f,usd,%s,%s,%04d' % (
                "".join(rng.choice(string.ascii_letters + string.digits) for _ in range(22)), time.strftime("%Y-%m-%d %H:%M:%S", t),
                name, email, plan, seats, amt, fee, amt - fee if status == "succeeded" else 0, status, brand, rng.randint(0, 9999)))
    return ("\n".join(lines) + "\n").encode("utf-8")


# ---------------------------------------------------------------- uploads

def multipart(body, kind):
    """Fields and files of a multipart/form-data body, binary safe."""
    m = re.search(r'boundary="?([^";]+)"?', kind or "")
    fields, files = {}, []
    if not m:
        return fields, files
    sep = b"--" + m.group(1).encode("latin-1")
    for chunk in body.split(sep)[1:]:
        if chunk.startswith(b"--"):
            break
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        head, _, data = chunk.partition(b"\r\n\r\n")
        if data.endswith(b"\r\n"):
            data = data[:-2]
        headers = head.decode("utf-8", "replace")
        disp = re.search(r"content-disposition:([^\r\n]*)", headers, re.I)
        if not disp:
            continue
        name = re.search(r'\bname="([^"]*)"', disp.group(1))
        filename = re.search(r'\bfilename="([^"]*)"', disp.group(1))
        ctype = re.search(r"content-type:\s*([^\r\n;]+)", headers, re.I)
        if filename is not None:
            if not filename.group(1) and not data:
                continue
            clean = filename.group(1).replace("%22", '"').replace("%0A", " ").replace("%0D", " ")
            files.append({"field": name.group(1) if name else "", "name": clean or "receipt",
                          "type": (ctype.group(1).strip() if ctype else "application/octet-stream"), "data": data})
        elif name:
            fields[name.group(1)] = data.decode("utf-8", "replace")
    return fields, files


def new_id(prefix):
    return prefix + "".join(random.choice(string.ascii_letters + string.digits) for _ in range(14))


def keep(expense, files):
    receipts = []
    for n, f in enumerate(files):
        key = "%s/%d" % (expense["id"], n)
        RECEIPTS[key] = (f["name"], f["type"], f["data"])
        receipts.append({"name": f["name"], "type": f["type"], "size": len(f["data"]),
                         "url": "/expenses/%s/receipts/%d" % (expense["id"], n)})
    # Keep memory bounded: the oldest receipts go first.
    total = sum(len(v[2]) for v in RECEIPTS.values())
    for k in list(RECEIPTS):
        if total <= RECEIPT_BUDGET:
            break
        total -= len(RECEIPTS[k][2])
        del RECEIPTS[k]
    return receipts


def add_expense(fields, files):
    try:
        amount = round(float((fields.get("amount") or "0").replace(",", "").replace("$", "").strip() or 0), 2)
    except ValueError:
        amount = 0.0
    expense = {
        "id": new_id("exp_"),
        "merchant": (fields.get("merchant") or "Untitled expense").strip()[:80],
        "amount": amount,
        "currency": (fields.get("currency") or "USD").upper()[:3],
        "date": (fields.get("date") or time.strftime("%Y-%m-%d")).strip()[:10],
        "category": (fields.get("category") or "Other").strip()[:40],
        "notes": (fields.get("notes") or "").strip()[:500],
        "by": "Mira Lindqvist",
        "created": time.time(),
    }
    with LOCK:
        expense["receipts"] = keep(expense, files)
        expense["status"] = "In review" if expense["receipts"] else "Needs receipt"
        EXPENSES.insert(0, expense)
    return expense


# ---------------------------------------------------------------- the routes

def attachment(ctx, data, kind, filename, rate):
    reply = ctx.html(data, 200, {"Content-Type": kind, "Content-Disposition": 'attachment; filename="%s"' % filename})
    reply.rate = rate
    return reply


def handle(req, ctx):
    path = req.path.rstrip("/") or "/"

    m = re.fullmatch(r"/invoices/([A-Za-z0-9-]+)\.pdf", path)
    if m and req.method in ("GET", "HEAD"):
        number = m.group(1).upper()
        return attachment(ctx, invoice_pdf(number), "application/pdf", "invoice-%s.pdf" % number, PDF_RATE)

    m = re.fullmatch(r"/reports/([a-z0-9-]+)\.csv", path)
    if m and req.method in ("GET", "HEAD"):
        report = m.group(1)
        data = report_csv(report)
        month = time.strftime("%Y-%m")
        name = report if re.search(r"\d{4}-\d{2}$", report) else "%s-%s" % (report, month)
        return attachment(ctx, data, "text/csv; charset=utf-8", "ledger-%s.csv" % name, max(4096, int(len(data) / CSV_SECONDS)))

    if path == "/expenses" and req.method == "POST":
        kind = req.headers.get("Content-Type") or ""
        if "multipart/form-data" in kind:
            fields, files = multipart(req.body, kind)
        else:
            fields, files = dict(req.form), []
        files = [f for f in files if f["field"] in ("receipt", "receipts", "file", "files", "")]
        expense = add_expense(fields, files)
        if "application/json" in (req.headers.get("Accept") or "") or req.json is not None:
            return ctx.json(expense)
        return ctx.redirect("/expenses?added=" + expense["id"])

    if path == "/api/expenses":
        with LOCK:
            return ctx.json({"expenses": EXPENSES})

    m = re.fullmatch(r"/expenses/(exp_[A-Za-z0-9]+)/receipts/(\d+)", path)
    if m:
        found = RECEIPTS.get("%s/%s" % (m.group(1), m.group(2)))
        if not found:
            return None
        name, kind, data = found
        reply = ctx.html(data, 200, {"Content-Type": kind or "application/octet-stream",
                                     "Content-Disposition": 'inline; filename="%s"' % name.replace('"', "")})
        return reply

    m = re.fullmatch(r"/payments/(py_[A-Za-z0-9]+)/retry", path)
    if m and req.method == "POST":
        time.sleep(0.9)
        return ctx.json({"id": m.group(1), "status": "succeeded", "amount": 24000, "currency": "usd",
                         "payment_method": {"brand": "visa", "last4": "8836"}})

    return None
