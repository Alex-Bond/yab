"""A small PDF writer: the standard fonts, text, lines and boxes, enough
for an invoice or a care guide. A4, points, origin at the bottom left."""

A4 = (595.28, 841.89)

# Glyph widths of the standard fonts (per 1000), for right-aligned numbers.
_HELV = {
    " ": 278, "!": 278, '"': 355, "#": 556, "$": 556, "%": 889, "&": 667, "'": 191, "(": 333, ")": 333,
    "*": 389, "+": 584, ",": 278, "-": 333, ".": 278, "/": 278, ":": 278, ";": 278, "<": 584, "=": 584,
    ">": 584, "?": 556, "@": 1015, "A": 667, "B": 667, "C": 722, "D": 722, "E": 667, "F": 611, "G": 778,
    "H": 722, "I": 278, "J": 500, "K": 667, "L": 556, "M": 833, "N": 722, "O": 778, "P": 667, "Q": 778,
    "R": 722, "S": 667, "T": 611, "U": 722, "V": 667, "W": 944, "X": 667, "Y": 667, "Z": 611, "[": 278,
    "]": 278, "_": 556, "a": 556, "b": 556, "c": 500, "d": 556, "e": 556, "f": 278, "g": 556, "h": 556,
    "i": 222, "j": 222, "k": 500, "l": 222, "m": 833, "n": 556, "o": 556, "p": 556, "q": 556, "r": 333,
    "s": 500, "t": 278, "u": 556, "v": 500, "w": 722, "x": 500, "y": 500, "z": 500, "ä": 556, "å": 556,
    "ö": 556, "é": 556, "Ö": 778, "Ä": 667, "Å": 667, "×": 584, "·": 278, "°": 400, "Ø": 778, "ø": 611,
}
_BOLD = dict(_HELV)
_BOLD.update({
    "!": 333, '"': 474, "&": 722, "'": 238, ":": 333, ";": 333, "?": 611, "@": 975, "A": 722, "B": 722,
    "J": 556, "K": 722, "L": 611, "[": 333, "]": 333, "b": 611, "c": 556, "d": 611, "f": 333, "g": 611,
    "h": 611, "i": 278, "j": 278, "k": 556, "l": 278, "m": 889, "n": 611, "o": 611, "p": 611, "q": 611,
    "r": 389, "t": 333, "u": 611, "v": 556, "w": 778, "x": 556, "y": 556, "ö": 611,
})
for _d in (_HELV, _BOLD):
    for _c in "0123456789":
        _d[_c] = 556


def width(text, size, bold=False):
    table = _BOLD if bold else _HELV
    return sum(table.get(ch, 556) for ch in text) * size / 1000.0


def _esc(text):
    raw = text.encode("cp1252", "replace")
    return raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


class Page:
    """One page's drawing, in PDF operators."""

    def __init__(self):
        self.ops = []

    def color(self, rgb, stroke=False):
        r, g, b = rgb
        self.ops.append(b"%.3f %.3f %.3f %s" % (r, g, b, b"RG" if stroke else b"rg"))

    def text(self, x, y, s, size=10, font="F1", rgb=(0.12, 0.11, 0.1), align="left", spacing=0):
        bold = font == "F2"
        if align == "right":
            x -= width(s, size, bold) + spacing * max(0, len(s) - 1)
        elif align == "center":
            x -= (width(s, size, bold) + spacing * max(0, len(s) - 1)) / 2
        self.color(rgb)
        tc = b" %.2f Tc" % spacing if spacing else b" 0 Tc"
        self.ops.append(b"BT /%s %.2f Tf%s 1 0 0 1 %.2f %.2f Tm (" % (font.encode(), size, tc, x, y)
                        + _esc(s) + b") Tj ET")

    def line(self, x1, y1, x2, y2, w=0.6, rgb=(0.85, 0.82, 0.78)):
        self.color(rgb, stroke=True)
        self.ops.append(b"%.2f w %.2f %.2f m %.2f %.2f l S" % (w, x1, y1, x2, y2))

    def box(self, x, y, w, h, rgb):
        self.color(rgb)
        self.ops.append(b"%.2f %.2f %.2f %.2f re f" % (x, y, w, h))

    def path(self, d, rgb):
        """A filled shape from (x, y) points, closed."""
        self.color(rgb)
        pts = [b"%.2f %.2f %s" % (x, y, b"m" if i == 0 else b"l") for i, (x, y) in enumerate(d)]
        self.ops.append(b" ".join(pts) + b" h f")

    def stream(self):
        return b"\n".join(self.ops)


def document(pages, title, pad_to=0):
    """The bytes of a PDF of these pages. `pad_to` grows it, with the
    XMP packet's own padding, to about that many bytes."""
    objs = {}
    n_pages = len(pages)
    page_ids = [7 + i * 2 for i in range(n_pages)]
    objs[1] = b"<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R >>"
    objs[2] = b"<< /Type /Pages /Kids [%s] /Count %d >>" % (b" ".join(b"%d 0 R" % p for p in page_ids), n_pages)
    objs[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    objs[4] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"
    objs[5] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >>"
    xmp = ('<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>'
           '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
           '<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">'
           '<dc:title><rdf:Alt><rdf:li xml:lang="x-default">%s</rdf:li></rdf:Alt></dc:title>'
           '<dc:creator><rdf:Seq><rdf:li>Nordbutik AB</rdf:li></rdf:Seq></dc:creator>'
           '</rdf:Description></rdf:RDF></x:xmpmeta>' % title).encode("utf-8")
    body_guess = 2600 + sum(len(p.stream()) for p in pages)
    pad = max(0, pad_to - body_guess - len(xmp) - 40)
    padding = b"\n".join([b" " * 99] * (pad // 100)) + b"\n"
    xmp = xmp + padding + b'<?xpacket end="w"?>'
    objs[6] = b"<< /Type /Metadata /Subtype /XML /Length %d >>\nstream\n" % len(xmp) + xmp + b"\nendstream"
    for i, page in enumerate(pages):
        pid, cid = page_ids[i], page_ids[i] + 1
        content = page.stream()
        objs[pid] = (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] "
                     b"/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents %d 0 R >>"
                     % (A4[0], A4[1], cid))
        objs[cid] = b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream"
    info_id = max(objs) + 1
    objs[info_id] = b"<< /Title (" + _esc(title) + b") /Producer (Nordbutik) /Creator (Nordbutik) >>"
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for i in sorted(objs):
        offsets[i] = len(out)
        out += b"%d 0 obj\n" % i + objs[i] + b"\nendobj\n"
    xref = len(out)
    size = max(objs) + 1
    out += b"xref\n0 %d\n0000000000 65535 f \n" % size
    for i in range(1, size):
        out += b"%010d 00000 n \n" % offsets[i]
    out += b"trailer\n<< /Size %d /Root 1 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (size, info_id, xref)
    return bytes(out)
