"""Nordbutik's product pictures: still lifes drawn in SVG, one per product
and color, a closer look at each, and a measured drawing.

Every object is drawn standing on y=0, centered on x=0, light from the
upper left, and a scene puts it on a seamless wall and floor."""
import random

W, H = 800, 1000


# ------------------------------------------------------------------ color

def _rgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def _hex(c):
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(v))) for v in c)


def mix(a, b, t):
    A, B = _rgb(a), _rgb(b)
    return _hex([A[i] + (B[i] - A[i]) * t for i in range(3)])


def lit(c, t):
    return mix(c, "#fffaf2", t)


def shade(c, t):
    return mix(c, "#2b2119", t)


class Defs:
    """Gradients, filters and patterns of one picture, each with its own id."""

    def __init__(self):
        self.parts = []
        self.n = 0

    def _id(self, kind):
        self.n += 1
        return "%s%d" % (kind, self.n)

    @staticmethod
    def _stops(stops):
        out = []
        for s in stops:
            a = s[2] if len(s) > 2 else 1
            op = ' stop-opacity="%s"' % a if a != 1 else ""
            out.append('<stop offset="%s" stop-color="%s"%s/>' % (s[0], s[1], op))
        return "".join(out)

    def lin(self, stops, x1=0, y1=0, x2=1, y2=0, user=False):
        i = self._id("l")
        u = ' gradientUnits="userSpaceOnUse"' if user else ""
        self.parts.append('<linearGradient id="%s" x1="%s" y1="%s" x2="%s" y2="%s"%s>%s</linearGradient>'
                          % (i, x1, y1, x2, y2, u, self._stops(stops)))
        return "url(#%s)" % i

    def rad(self, stops, cx=.5, cy=.5, r=.5, fx=None, fy=None, user=False):
        i = self._id("r")
        u = ' gradientUnits="userSpaceOnUse"' if user else ""
        f = ""
        if fx is not None:
            f = ' fx="%s" fy="%s"' % (fx, fy)
        self.parts.append('<radialGradient id="%s" cx="%s" cy="%s" r="%s"%s%s>%s</radialGradient>'
                          % (i, cx, cy, r, f, u, self._stops(stops)))
        return "url(#%s)" % i

    def blur(self, std):
        i = self._id("b")
        self.parts.append('<filter id="%s" x="-30%%" y="-30%%" width="160%%" height="160%%">'
                          '<feGaussianBlur stdDeviation="%s"/></filter>' % (i, std))
        return "url(#%s)" % i

    def clip(self, d):
        i = self._id("c")
        self.parts.append('<clipPath id="%s"><path d="%s"/></clipPath>' % (i, d))
        return "url(#%s)" % i

    def weave(self, color, size=5, op=.10):
        """A linen's threads, as fine lines both ways."""
        i = self._id("w")
        s = size
        self.parts.append(
            '<pattern id="%s" width="%s" height="%s" patternUnits="userSpaceOnUse">'
            '<rect width="%s" height="1.1" fill="%s" opacity="%s"/>'
            '<rect width="1" height="%s" fill="%s" opacity="%s"/>'
            '<rect x="%s" y="%s" width="1.2" height="1.2" fill="#fff" opacity="%s"/>'
            '</pattern>' % (i, s, s, s, color, op, s, color, op * .7, s / 2, s / 2, op * .8))
        return "url(#%s)" % i

    def svg(self):
        return "<defs>%s</defs>" % "".join(self.parts)


def _soft(d, cx, cy, rx, ry, op, color="#3a2a1c"):
    """A soft shadow on the floor."""
    g = d.rad([(0, color, op), (.55, color, op * .45), (1, color, 0)])
    return '<ellipse cx="%s" cy="%s" rx="%s" ry="%s" fill="%s"/>' % (cx, cy, rx, ry, g)


# ------------------------------------------------------------------ objects
#
# Each returns markup in its own coordinates plus where it sits: a box
# (x0, y0, x1, y1), a floor shadow (cx, cy, rx, ry, opacity) and an
# optional silhouette for the shadow it throws on the wall.

LAMP = {"opal": None, "smoke": None}


def lamp(d, color, cord=True, glow=True):
    smoke = color == "smoke"
    out = []
    halo = d.rad([(0, "#fff4da", .8 if not smoke else .55), (.3, "#ffe3b5", .42 if not smoke else .3),
                  (.62, "#ffd9a6", .12), (1, "#ffd9a6", 0)])
    if glow:
        out.append('<circle cx="0" cy="-262" r="380" fill="%s"/>' % halo)
    # the cord, across the table to the edge of the picture
    if cord:
        out.append('<path d="M66,-6 C150,8 230,46 470,62" fill="none" stroke="#1f1814" stroke-width="5" '
                   'stroke-linecap="round" opacity=".85"/>')
    brass = d.lin([(0, "#5c4226"), (.14, "#a07c48"), (.28, "#ead29c"), (.4, "#c79f60"),
                   (.68, "#8a673b"), (1, "#523a20")])
    out.append('<path d="M-78,-112 L-78,0 A78,15 0 0 0 78,0 L78,-112 Z" fill="%s"/>' % brass)
    ring = d.lin([(0, "#3b2a17", .0), (.5, "#3b2a17", .25), (1, "#3b2a17", 0)])
    out.append('<path d="M-78,-30 A78,15 0 0 0 78,-30" fill="none" stroke="%s" stroke-width="2"/>' % ring)
    top = d.lin([(0, "#f0d9a6"), (.5, "#c9a265"), (1, "#8f6c3c")], 0, 0, 1, 1)
    out.append('<ellipse cx="0" cy="-112" rx="78" ry="15" fill="%s"/>' % top)
    out.append('<ellipse cx="0" cy="-113" rx="58" ry="10" fill="#5a4024" opacity=".55"/>')
    if smoke:
        g = d.rad([(0, "#fde8c6"), (.28, "#d8bd98"), (.7, "#937f6c"), (1, "#5e534a")], .42, .42, .62, .38, .36)
    else:
        g = d.rad([(0, "#ffffff"), (.42, "#fffaf0"), (.8, "#f6e8d1"), (1, "#e2caa6")], .42, .40, .62, .38, .34)
    out.append('<circle cx="0" cy="-262" r="152" fill="%s"/>' % g)
    foot = d.lin([(0, "#3a2a1c", 0), (.78, "#3a2a1c", 0), (1, "#3a2a1c", .22 if smoke else .16)], 0, 0, 0, 1)
    out.append('<circle cx="0" cy="-262" r="152" fill="%s"/>' % foot)
    out.append('<ellipse cx="-58" cy="-334" rx="48" ry="25" transform="rotate(-36 -58 -334)" '
               'fill="#ffffff" opacity="%s"/>' % (".32" if smoke else ".6"))
    out.append('<ellipse cx="-30" cy="-118" rx="26" ry="4" fill="#fff6dc" opacity=".55"/>')
    return "".join(out), (-152, -414, 152, 16), (40, 4, 150, 24, .30), None


def throw(d, color):
    base = {"sand": "#d5c1a1", "moss": "#7b8261", "charcoal": "#4b4a47"}[color]
    oak = "#c79f70"
    out = []
    # the bench it lies on
    seat = -236
    slab_front = d.lin([(0, lit(oak, .1)), (1, shade(oak, .12))], 0, 0, 0, 1)
    slab_top = d.lin([(0, shade(oak, .05)), (1, lit(oak, .22))], 0, 0, 0, 1)
    leg = d.lin([(0, lit(oak, .12)), (.35, oak), (1, shade(oak, .28))])
    out.append('<rect x="-250" y="%s" width="40" height="%s" fill="%s"/>' % (seat + 36, -seat - 36, leg))
    out.append('<rect x="210" y="%s" width="40" height="%s" fill="%s"/>' % (seat + 36, -seat - 36, leg))
    out.append('<rect x="-250" y="%s" width="500" height="10" fill="%s" opacity=".25"/>' % (seat + 36, shade(oak, .6)))
    out.append('<path d="M-268,%s L268,%s L280,%s L-280,%s Z" fill="%s"/>' % (seat - 18, seat - 18, seat, seat, slab_top))
    out.append('<rect x="-280" y="%s" width="560" height="38" rx="3" fill="%s"/>' % (seat, slab_front))
    out.append('<rect x="-280" y="%s" width="560" height="2" fill="#fff" opacity=".35"/>' % seat)
    # the throw, folded in four: a top, and the folds' rounded edges in front
    y = seat - 8
    heights = (25, 23, 27, 24)
    edges = [y]
    for h in heights:
        edges.insert(0, edges[0] - h)
    top = edges[0]
    left = ["M-220,%s" % top]
    for a, b in zip(edges, edges[1:]):
        left.append("Q-231,%.1f -221,%.1f" % ((a + b) / 2, b))
    right = []
    for a, b in zip(reversed(edges[1:]), reversed(edges[:-1])):
        right.append("Q231,%.1f 221,%.1f" % ((a + b) / 2, b))
    front = " ".join(left) + " L221,%s " % edges[-1] + " ".join(right) + " Z"
    front = front.replace("L221,%s Q231" % edges[-1], "L221,%s Q231" % edges[-1])
    top_face = "M-220,%s C-214,%s -206,%s -194,%s L194,%s C206,%s 214,%s 220,%s Z" % (
        top, top - 28, top - 48, top - 56, top - 56, top - 48, top - 28, top)
    tf = d.lin([(0, shade(base, .07)), (.7, lit(base, .1)), (1, lit(base, .18))], 0, 0, 0, 1)
    out.append('<path d="%s" fill="%s"/>' % (top_face, tf))
    out.append('<path d="%s" fill="%s"/>' % (top_face, d.weave(shade(base, .5), 5, .09)))
    for k, (x0, x1, dy) in enumerate(((-150, 40, 18), (-60, 170, 34))):
        out.append('<path d="M%s,%s C%s,%s %s,%s %s,%s" fill="none" stroke="%s" stroke-width="2" opacity=".3"/>'
                   % (x0, top - dy, x0 + 60, top - dy + 5, x1 - 60, top - dy - 6, x1, top - dy - 2, shade(base, .35)))
        out.append('<path d="M%s,%s C%s,%s %s,%s %s,%s" fill="none" stroke="%s" stroke-width="1.6" opacity=".45"/>'
                   % (x0, top - dy + 3, x0 + 60, top - dy + 8, x1 - 60, top - dy - 3, x1, top - dy + 1, lit(base, .4)))
    clip = d.clip(front)
    out.append('<g clip-path="%s">' % clip)
    for a, b in zip(edges, edges[1:]):
        g = d.lin([(0, lit(base, .22)), (.3, lit(base, .06)), (.78, shade(base, .1)), (1, shade(base, .3))], 0, 0, 0, 1)
        out.append('<path d="M-240,%s C-100,%s 100,%s 240,%s L240,%s C100,%s -100,%s -240,%s Z" fill="%s"/>'
                   % (a, a + 3, a + 3, a, b + 1, b + 4, b + 4, b + 1, g))
    out.append('<rect x="-240" y="%s" width="480" height="%s" fill="%s"/>' % (top - 4, y - top + 8, d.weave(shade(base, .5), 5, .12)))
    side = d.lin([(0, "#fff", .2), (.1, "#fff", 0), (.86, "#2b2119", 0), (1, "#2b2119", .22)])
    out.append('<rect x="-240" y="%s" width="480" height="%s" fill="%s"/>' % (top - 4, y - top + 8, side))
    out.append("</g>")
    # the fringe of the last fold, over the bench's edge
    rnd = random.Random(7)
    fr = []
    x = -204
    while x <= 204:
        ln = 18 + rnd.random() * 9
        lean = rnd.uniform(-2.5, 2.5)
        fr.append("M%.1f,%s q%.1f,%.1f %.1f,%.1f" % (x, y - 1, lean * .5, ln * .5, lean, ln))
        x += 5.2
    out.append('<path d="%s" fill="none" stroke="%s" stroke-width="2.2" stroke-linecap="round"/>'
               % (" ".join(fr), shade(base, .14)))
    out.append('<path d="%s" fill="none" stroke="%s" stroke-width="1" stroke-linecap="round" opacity=".5" transform="translate(-1,0)"/>'
               % (" ".join(fr), lit(base, .25)))
    return "".join(out), (-280, top - 56, 280, 0), (30, 6, 330, 30, .32), None


def _mug(d, glaze, rnd, inner_glow=True):
    out = []
    body = d.lin([(0, shade(glaze, .1)), (.16, lit(glaze, .14)), (.36, glaze), (.72, shade(glaze, .12)),
                  (.93, shade(glaze, .24)), (1, shade(glaze, .16))])
    # the handle, behind the body's right edge
    out.append('<path d="M68,-142 C140,-148 146,-58 70,-56" fill="none" stroke="%s" stroke-width="20" stroke-linecap="round"/>'
               % shade(glaze, .2))
    out.append('<path d="M70,-146 C134,-150 140,-66 76,-60" fill="none" stroke="%s" stroke-width="5" stroke-linecap="round" opacity=".5"/>'
               % lit(glaze, .2))
    out.append('<path d="M-76,-172 L-76,0 A76,21 0 0 0 76,0 L76,-172 Z" fill="%s"/>' % body)
    # raw clay at the foot
    clay = "#c7a17d"
    foot = d.lin([(0, shade(clay, .08)), (.2, lit(clay, .1)), (.6, clay), (1, shade(clay, .3))])
    out.append('<path d="M-76,-16 C-50,-2 -26,6 0,5 C30,6 52,-1 76,-16 L76,0 A76,21 0 0 1 -76,0 Z" fill="%s"/>' % foot)
    out.append('<path d="M-76,-16 C-50,-2 -26,6 0,5 C30,6 52,-1 76,-16" fill="none" stroke="%s" stroke-width="1.6" opacity=".55"/>'
               % shade(glaze, .25))
    # speckles in the glaze
    dots = []
    for _ in range(46):
        x = rnd.uniform(-68, 68)
        y = rnd.uniform(-160, -18)
        dots.append('<circle cx="%.1f" cy="%.1f" r="%.1f"/>' % (x, y, rnd.uniform(.8, 2.1)))
    out.append('<g fill="#3a2a1c" opacity=".32">%s</g>' % "".join(dots))
    # the rim and the inside
    out.append('<ellipse cx="0" cy="-172" rx="76" ry="21" fill="%s"/>' % lit(glaze, .25))
    inside = d.lin([(0, lit(glaze, .05)), (.55, shade(glaze, .22)), (1, shade(glaze, .45))], 0, 0, 0, 1)
    out.append('<ellipse cx="0" cy="-170" rx="68" ry="16.5" fill="%s"/>' % inside)
    out.append('<path d="M-68,-170 A68,16.5 0 0 0 68,-170" fill="none" stroke="%s" stroke-width="2" opacity=".6"/>'
               % lit(glaze, .45))
    out.append('<rect x="-56" y="-150" width="10" height="118" rx="5" fill="#fff" opacity=".16"/>')
    return "".join(out)


def mugs(d, color):
    glaze = {"chalk": "#ece5d9", "fjord": "#8ea4a6", "clay": "#c4856a"}[color]
    rnd = random.Random(11)
    out = []
    out.append(_soft(d, 168, -24, 130, 22, .26))
    out.append('<g transform="translate(110,-34) scale(.9)">%s</g>' % _mug(d, shade(glaze, .04), rnd))
    out.append(_soft(d, -40, 8, 140, 24, .34))
    out.append('<g transform="translate(-98,0)">%s</g>' % _mug(d, glaze, rnd))
    return "".join(out), (-174, -205, 238, 22), (40, 6, 210, 30, .18), None


def _tile_pattern(d, ink, pale, accent, glaze="#f3eee3"):
    """One tile, 220 across, in its own coordinates."""
    s = 220
    p = []
    p.append('<rect width="%s" height="%s" rx="10" fill="%s"/>' % (s, s, glaze))
    # quarter circles at the corners, a whole one where four tiles meet
    for cx, cy in ((0, 0), (s, 0), (0, s), (s, s)):
        p.append('<circle cx="%s" cy="%s" r="62" fill="%s"/>' % (cx, cy, ink))
        p.append('<circle cx="%s" cy="%s" r="44" fill="%s"/>' % (cx, cy, glaze))
        p.append('<circle cx="%s" cy="%s" r="30" fill="%s"/>' % (cx, cy, pale))
        p.append('<circle cx="%s" cy="%s" r="12" fill="%s"/>' % (cx, cy, accent))
    c = s / 2
    # the flower in the middle
    for a in (0, 90):
        p.append('<ellipse cx="%s" cy="%s" rx="22" ry="62" fill="%s" transform="rotate(%s %s %s)"/>' % (c, c, ink, a, c, c))
    for a in (45, 135):
        p.append('<ellipse cx="%s" cy="%s" rx="13" ry="44" fill="%s" transform="rotate(%s %s %s)"/>' % (c, c, pale, a, c, c))
    p.append('<circle cx="%s" cy="%s" r="20" fill="%s"/>' % (c, c, glaze))
    p.append('<circle cx="%s" cy="%s" r="11" fill="%s"/>' % (c, c, accent))
    # dots on the axes
    for x, y in ((c, 18), (c, s - 18), (18, c), (s - 18, c)):
        p.append('<circle cx="%s" cy="%s" r="6" fill="%s"/>' % (x, y, ink))
    p.append('<rect x="3" y="3" width="%s" height="%s" rx="8" fill="none" stroke="%s" stroke-width="2" opacity=".35"/>'
             % (s - 6, s - 6, ink))
    return '<g clip-path="%s">%s</g>' % (d.clip("M10,0 H210 A10,10 0 0 1 220,10 V210 A10,10 0 0 1 210,220 H10 A10,10 0 0 1 0,210 V10 A10,10 0 0 1 10,0 Z"), "".join(p))


TILES = {"azul": ("#2d4c8a", "#91b1d8", "#d6a446"), "terracotta": ("#a8502f", "#e2a57d", "#55705d")}


def coasters(d, color):
    ink, pale, accent = TILES[color]
    tile = _tile_pattern(d, ink, pale, accent)
    out = []
    # a stack of three, lying flat
    out.append(_soft(d, -90, 10, 200, 40, .28))
    for i, y in enumerate((-8, -26, -44)):
        flat = 'translate(-110,%s) scale(1,.42) rotate(24) translate(-110,-110)' % y
        out.append('<g transform="translate(0,12)"><g transform="%s"><rect width="220" height="220" rx="10" fill="#b8936a"/></g></g>' % flat)
        out.append('<g transform="translate(0,6)"><g transform="%s"><rect width="220" height="220" rx="10" fill="%s"/></g></g>'
                   % (flat, mix("#b8936a", "#f3eee3", .5)))
        out.append('<g transform="%s">%s</g>' % (flat, tile))
    sheen = d.lin([(0, "#fff", 0), (.45, "#fff", .32), (.55, "#fff", .05), (1, "#fff", 0)], 0, 0, 1, 1)
    out.append('<g transform="translate(-110,-44) scale(1,.42) rotate(24) translate(-110,-110)">'
               '<rect width="220" height="220" rx="10" fill="%s"/></g>' % sheen)
    # one standing, leaning back on the wall of the stack
    out.append(_soft(d, 170, 6, 150, 22, .3))
    out.append('<g transform="translate(150,0) rotate(4) translate(-110,-232)">')
    out.append('<rect x="4" y="10" width="220" height="226" rx="10" fill="#b48d64"/>')
    out.append(tile)
    out.append('<rect width="220" height="220" rx="10" fill="%s"/>' % d.lin(
        [(0, "#fff", .38), (.3, "#fff", .06), (.62, "#2b2119", 0), (1, "#2b2119", .14)], 0, 0, 1, 1))
    out.append('<rect x="0" y="218" width="220" height="12" rx="4" fill="#c49b6e"/>')
    out.append("</g>")
    return "".join(out), (-260, -250, 280, 20), (0, 0, 0, 0, 0), None


def board(d, color):
    wood = {"natural": "#cfa472", "smoked": "#7b5c44"}[color]
    out = []
    shape = ("M-112,-430 Q-112,-452 -90,-452 L-46,-452 L-40,-548 Q-38,-580 0,-580 Q38,-580 40,-548 L46,-452 "
             "L90,-452 Q112,-452 112,-430 L112,-18 Q112,0 92,0 L-92,0 Q-112,0 -112,-18 Z")
    edge = d.lin([(0, shade(wood, .35)), (1, shade(wood, .2))])
    out.append('<path d="%s" fill="%s" transform="translate(12,2)"/>' % (shape, edge))
    face = d.lin([(0, lit(wood, .18)), (.3, lit(wood, .06)), (.7, wood), (1, shade(wood, .14))])
    out.append('<path d="%s" fill="%s"/>' % (shape, face))
    clip = d.clip(shape)
    rnd = random.Random(5)
    lines = []
    for i in range(15):
        x = -104 + i * 15 + rnd.uniform(-4, 4)
        a, b = rnd.uniform(-9, 9), rnd.uniform(-9, 9)
        lines.append('<path d="M%.1f,10 C%.1f,-160 %.1f,-330 %.1f,-600" fill="none" stroke="%s" stroke-width="%.1f" opacity="%.2f"/>'
                     % (x, x + a, x + b, x + a * .5, shade(wood, .4), rnd.uniform(.8, 2.2), rnd.uniform(.18, .38)))
    # a cathedral figure in the grain
    for k in range(5):
        w = 18 + k * 9
        lines.append('<path d="M%s,-40 C%s,-170 %s,-230 10,%s C%s,-230 %s,-170 %s,-40" fill="none" stroke="%s" stroke-width="1.4" opacity=".28"/>'
                     % (10 - w, 10 - w, 10 - w * .6, -250 - k * 22, 10 + w * .6, 10 + w, 10 + w, shade(wood, .45)))
    out.append('<g clip-path="%s">%s</g>' % (clip, "".join(lines)))
    out.append('<circle cx="0" cy="-540" r="15" fill="%s"/>' % shade(wood, .55))
    out.append('<path d="M-11,-548 A15,15 0 0 1 13,-544" fill="none" stroke="%s" stroke-width="3" opacity=".6"/>' % shade(wood, .7))
    out.append('<path d="M-106,-440 L-106,-30" stroke="#fff" stroke-width="3" opacity=".22"/>')
    return "".join(out), (-112, -580, 124, 2), (60, -4, 160, 18, .3), shape


def lemon(d, x, y, s=1):
    peel = d.rad([(0, "#fbe58a"), (.55, "#f1c94a"), (1, "#c99a24")], .38, .35, .7)
    return ('<g transform="translate(%s,%s) scale(%s)">' % (x, y, s)
            + _soft(d, 30, 6, 90, 16, .3)
            + '<path d="M-74,-44 C-80,-60 -66,-70 -56,-66 C-30,-96 40,-96 62,-62 C74,-66 84,-52 76,-40 C82,-8 52,10 0,10 C-52,10 -82,-8 -74,-44 Z" fill="%s"/>' % peel
            + '<ellipse cx="-22" cy="-62" rx="22" ry="9" fill="#fffbe0" opacity=".55" transform="rotate(-12 -22 -62)"/>'
            + '<path d="M54,-72 C70,-110 110,-112 128,-100 C110,-82 80,-74 54,-72 Z" fill="#7d8a52"/>'
            + '<path d="M54,-72 C80,-90 104,-98 128,-100" fill="none" stroke="#5e6a3a" stroke-width="2"/>'
            + "</g>")


def rug(d, color):
    base, band, line = {"oat": ("#dcd1bf", "#c8bba5", "#4c4741"), "slate": ("#5f6771", "#6f7882", "#dcd2c2")}[color]
    out = []
    # the rug in perspective: the near edge wide, the far edge narrow
    nl, nr, fl, fr_, ny, fy = -390, 390, -262, 262, 0, -250
    shape = "M%s,%s L%s,%s L%s,%s L%s,%s Z" % (fl, fy, fr_, fy, nr, ny, nl, ny)
    out.append('<path d="%s" fill="%s" transform="translate(0,6)" opacity=".35"/>' % (shape, shade(base, .5)))
    g = d.lin([(0, shade(base, .1)), (.6, base), (1, lit(base, .08))], 0, 0, 0, 1)
    out.append('<path d="%s" fill="%s"/>' % (shape, g))
    clip = d.clip(shape)
    inner = []

    def depth(t):
        # where a line t of the way from far to near lands, foreshortened
        return fy + (ny - fy) * (t ** 1.35)
    # bands across
    for t0, t1 in ((.06, .14), (.42, .5), (.86, .94)):
        y0, y1 = depth(t0), depth(t1)
        inner.append('<path d="M-400,%.1f L400,%.1f L400,%.1f L-400,%.1f Z" fill="%s"/>' % (y0, y0, y1, y1, band))
    for t in (.1, .46, .9):
        y = depth(t)
        inner.append('<path d="M-400,%.1f L400,%.1f" stroke="%s" stroke-width="%.1f" opacity=".8"/>' % (y, y, line, 1 + t * 1.6))
    # pinstripes along, meeting far away
    vx, vy = 0, -1050
    for i in range(-9, 10):
        x = i * 42
        inner.append('<path d="M%s,%s L%s,%s" stroke="%s" stroke-width="1.4" opacity=".35"/>' % (x, ny, vx + x * .2, vy, line))
    inner.append('<rect x="-400" y="-260" width="800" height="270" fill="%s"/>' % d.weave(shade(base, .55), 6, .1))
    out.append('<g clip-path="%s">%s</g>' % (clip, "".join(inner)))
    # the near corner folded over
    flap = "M250,0 L390,0 L322,-112 Z"
    out.append('<path d="M250,0 L390,0 L326,-104 Z" fill="%s" opacity=".35" transform="translate(-10,6)"/>' % shade(base, .6))
    under = d.lin([(0, lit(base, .14)), (1, shade(base, .08))], 0, 0, 1, 1)
    out.append('<path d="%s" fill="%s"/>' % (flap, under))
    out.append('<path d="%s" fill="%s"/>' % (flap, d.weave(shade(base, .5), 4, .12)))
    out.append('<path d="M250,0 L322,-112" stroke="%s" stroke-width="2" opacity=".25"/>' % shade(base, .6))
    # fringe on the near edge
    rnd = random.Random(3)
    fr = []
    x = nl + 8
    while x < 246:
        ln = 18 + rnd.random() * 8
        fr.append("M%.1f,1 l%.1f,%.1f" % (x, rnd.uniform(-2, 2), ln))
        x += 5.5
    out.append('<path d="%s" stroke="%s" stroke-width="2.2" stroke-linecap="round"/>' % (" ".join(fr), lit(base, .2) if color == "oat" else lit(base, .35)))
    out.append('<path d="%s" stroke="%s" stroke-width="1" stroke-linecap="round" opacity=".4" transform="translate(1,0)"/>' % (" ".join(fr), shade(base, .4)))
    return "".join(out), (-390, -250, 390, 26), (0, 0, 0, 0, 0), None


def stool(d, x, y, s=1, wood="#b98e60"):
    seat_top = d.rad([(0, lit(wood, .28)), (1, wood)], .4, .4, .7)
    side = d.lin([(0, lit(wood, .12)), (.4, wood), (1, shade(wood, .3))])
    leg = d.lin([(0, lit(wood, .1)), (1, shade(wood, .32))])
    return ('<g transform="translate(%s,%s) scale(%s)">' % (x, y, s)
            + _soft(d, 30, 4, 150, 22, .3)
            + '<path d="M-92,-250 L-118,0 L-104,0 L-74,-250 Z" fill="%s"/>' % leg
            + '<path d="M92,-250 L118,0 L104,0 L74,-250 Z" fill="%s"/>' % leg
            + '<path d="M-10,-250 L-6,-12 L10,-12 L12,-250 Z" fill="%s"/>' % shade(wood, .25)
            + '<path d="M-110,-276 L-110,-252 A110,22 0 0 0 110,-252 L110,-276 Z" fill="%s"/>' % side
            + '<ellipse cx="0" cy="-276" rx="110" ry="22" fill="%s"/>' % seat_top
            + "</g>")


def carafe(d, color):
    amber = color == "amber"
    tint = "#c47f34" if amber else "#bcd3cf"
    out = []
    # light through the glass, on the table
    caustic = d.rad([(0, "#fff7e0" if not amber else "#ffd38a", .85), (1, "#fff7e0", 0)])
    out.append('<ellipse cx="142" cy="2" rx="130" ry="20" fill="%s"/>' % d.rad(
        [(0, shade(tint, .5), .32), (1, shade(tint, .5), 0)]))
    out.append('<ellipse cx="150" cy="0" rx="58" ry="9" fill="%s"/>' % caustic)
    shape = ("M-80,0 Q-96,0 -96,-18 L-96,-206 C-96,-266 -38,-268 -36,-312 L-36,-378 Q-36,-386 -44,-390 "
             "L-44,-396 L44,-396 L44,-390 Q36,-386 36,-378 L36,-312 C38,-268 96,-266 96,-206 L96,-18 Q96,0 80,0 Z")
    clip = d.clip(shape)
    out.append('<path d="%s" fill="%s" opacity="%s"/>' % (shape, tint, ".5" if amber else ".22"))
    # water
    water = d.lin([(0, tint, .25 if not amber else .35), (1, shade(tint, .3), .4)], 0, 0, 0, 1)
    out.append('<g clip-path="%s">' % clip)
    out.append('<rect x="-100" y="-150" width="200" height="160" fill="%s"/>' % water)
    out.append('<ellipse cx="0" cy="-150" rx="96" ry="9" fill="#fff" opacity=".35"/>')
    out.append('<path d="M-96,-150 A96,9 0 0 0 96,-150" fill="none" stroke="#fff" stroke-width="2" opacity=".7"/>')
    edges = d.lin([(0, "#3a2a1c", .32), (.05, "#fff", .7), (.11, "#fff", .1), (.5, "#fff", 0),
                   (.84, "#fff", .1), (.92, "#3a2a1c", .2), (1, "#2b2119", .45)])
    out.append('<rect x="-100" y="-400" width="200" height="410" fill="%s"/>' % edges)
    out.append('<rect x="-74" y="-200" width="9" height="170" rx="4.5" fill="#fff" opacity=".7"/>')
    out.append('<rect x="-58" y="-190" width="3" height="120" rx="1.5" fill="#fff" opacity=".45"/>')
    out.append('<rect x="-26" y="-370" width="6" height="52" rx="3" fill="#fff" opacity=".6"/>')
    out.append('<path d="M-90,-14 A90,10 0 0 0 90,-14" fill="none" stroke="#2b2119" stroke-width="7" opacity=".14"/>')
    out.append("</g>")
    out.append('<path d="%s" fill="none" stroke="%s" stroke-width="2" opacity=".55"/>' % (shape, shade(tint, .55)))
    out.append('<ellipse cx="0" cy="-396" rx="44" ry="7" fill="none" stroke="%s" stroke-width="2" opacity=".6"/>' % shade(tint, .5))
    out.append('<ellipse cx="0" cy="-396" rx="44" ry="7" fill="#fff" opacity=".2"/>')
    # a tumbler beside it
    out.append('<g transform="translate(178,46)">')
    out.append('<ellipse cx="70" cy="2" rx="80" ry="12" fill="%s"/>' % d.rad([(0, shade(tint, .5), .26), (1, shade(tint, .5), 0)]))
    t = "M-54,-128 L-48,-8 Q-47,0 -38,0 L38,0 Q47,0 48,-8 L54,-128 Z"
    tclip = d.clip(t)
    out.append('<path d="%s" fill="%s" opacity="%s"/>' % (t, tint, ".5" if amber else ".22"))
    out.append('<g clip-path="%s"><rect x="-60" y="-70" width="120" height="80" fill="%s"/>' % (tclip, water))
    out.append('<rect x="-60" y="-140" width="120" height="150" fill="%s"/>' % edges)
    out.append('<rect x="-40" y="-110" width="7" height="90" rx="3.5" fill="#fff" opacity=".6"/></g>')
    out.append('<path d="%s" fill="none" stroke="%s" stroke-width="2" opacity=".5"/>' % (t, shade(tint, .55)))
    out.append('<ellipse cx="0" cy="-128" rx="54" ry="8" fill="none" stroke="%s" stroke-width="2" opacity=".55"/>' % shade(tint, .5))
    out.append('<ellipse cx="0" cy="-70" rx="51" ry="7" fill="#fff" opacity=".3"/>')
    out.append("</g>")
    return "".join(out), (-96, -400, 232, 46), (0, 0, 0, 0, 0), shape


def apron(d, color):
    cloth = {"sand": "#d4c1a2", "moss": "#7c8461", "rust": "#a45a3d"}[color]
    out = []
    strap = shade(cloth, .08)
    # the neck strap over the peg
    out.append('<path d="M-8,4 C-30,30 -56,80 -70,128 M8,4 C30,30 56,80 70,128" fill="none" stroke="%s" stroke-width="15" stroke-linecap="round"/>' % strap)
    out.append('<path d="M-6,0 C-26,28 -52,78 -66,126 M10,0 C30,28 54,78 66,126" fill="none" stroke="%s" stroke-width="3" opacity=".35"/>' % lit(cloth, .4))
    body = ("M-84,120 L84,120 C88,170 96,214 118,252 C126,262 132,276 134,300 C150,420 168,600 176,760 "
            "C110,772 -110,772 -176,760 C-168,600 -150,420 -134,300 C-132,276 -126,262 -118,252 C-96,214 -88,170 -84,120 Z")
    g = d.lin([(0, shade(cloth, .12)), (.18, lit(cloth, .1)), (.5, cloth), (.82, shade(cloth, .1)), (1, shade(cloth, .22))])
    out.append('<path d="%s" fill="%s"/>' % (body, g))
    clip = d.clip(body)
    inner = []
    # folds that fall from the waist
    for x, w, op in ((-70, 34, .1), (22, 26, .07), (104, 30, .1)):
        fold = d.lin([(0, "#2b2119", 0), (.5, "#2b2119", op), (1, "#2b2119", 0)])
        inner.append('<path d="M%s,320 C%s,500 %s,640 %s,790 L%s,790 C%s,640 %s,500 %s,320 Z" fill="%s"/>'
                     % (x, x - 6, x - 12, x - 18, x - 18 + w, x - 12 + w, x - 6 + w, x + w, fold))
    for x in (-24, 70):
        hi = d.lin([(0, "#fff", 0), (.5, "#fff", .08), (1, "#fff", 0)])
        inner.append('<path d="M%s,330 C%s,500 %s,640 %s,790 L%s,790 C%s,640 %s,500 %s,330 Z" fill="%s"/>'
                     % (x, x - 4, x - 8, x - 12, x + 10, x + 14, x + 18, x + 22, hi))
    inner.append('<rect x="-200" y="100" width="400" height="700" fill="%s"/>' % d.weave(shade(cloth, .5), 5, .1))
    out.append('<g clip-path="%s">%s</g>' % (clip, "".join(inner)))
    # waist ties, hanging
    tie = shade(cloth, .06)
    out.append('<path d="M-128,300 C-150,380 -132,450 -150,560" fill="none" stroke="%s" stroke-width="15" stroke-linecap="round"/>' % tie)
    out.append('<path d="M128,300 C156,370 140,470 158,590" fill="none" stroke="%s" stroke-width="15" stroke-linecap="round"/>' % tie)
    out.append('<path d="M-128,300 C-150,380 -132,450 -150,560" fill="none" stroke="#fff" stroke-width="3" opacity=".22" transform="translate(-4,0)"/>')
    # the pocket, with its stitching
    out.append('<path d="M-112,440 L112,440 L116,566 Q116,578 104,578 L-104,578 Q-116,578 -116,566 Z" fill="%s"/>' % shade(cloth, .07))
    out.append('<path d="M-112,440 L112,440" stroke="%s" stroke-width="3" opacity=".5"/>' % shade(cloth, .3))
    out.append('<path d="M-104,452 L104,452 M0,452 L0,570 M-106,452 L-108,568 M106,452 L108,568" fill="none" stroke="%s" stroke-width="1.6" stroke-dasharray="6 5" opacity=".7"/>' % lit(cloth, .45))
    # hem
    out.append('<path d="M-172,744 C-110,756 110,756 172,744" fill="none" stroke="%s" stroke-width="1.6" stroke-dasharray="6 5" opacity=".7"/>' % lit(cloth, .45))
    out.append('<path d="M-80,134 L80,134" fill="none" stroke="%s" stroke-width="1.6" stroke-dasharray="6 5" opacity=".7"/>' % lit(cloth, .45))
    return "".join(out), (-180, 0, 180, 772), (0, 0, 0, 0, 0), body


# ------------------------------------------------------------------ scenes

def backdrop(d, w, h, wall, floor, horizon, window=True):
    out = []
    g = d.lin([(0, lit(wall, .1)), (1, shade(wall, .04))], 0, 0, 0, 1)
    out.append('<rect width="%s" height="%s" fill="%s"/>' % (w, horizon + 60, g))
    glow = d.rad([(0, "#fffaf0", .55), (1, "#fffaf0", 0)], .22, .18, .85)
    out.append('<rect width="%s" height="%s" fill="%s"/>' % (w, horizon + 60, glow))
    if window:
        beam = d.lin([(0, "#fffdf6", .34), (1, "#fffdf6", 0)], 0, 0, .4, 1)
        x = w * .06
        out.append('<path d="M%s,0 L%s,0 L%s,%s L%s,%s Z" fill="%s"/>' % (x, x + w * .34, x + w * .6, horizon, x + w * .28, horizon, beam))
        out.append('<path d="M%s,0 L%s,0 L%s,%s L%s,%s Z" fill="%s" opacity=".55"/>'
                   % (x + w * .15, x + w * .175, x + w * .44, horizon, x + w * .415, horizon, lit(wall, .0)))
    # the floor sweeps up into the wall
    fl = d.lin([(0, floor), (.12, lit(floor, .06)), (1, shade(floor, .1))], 0, 0, 0, 1)
    out.append('<rect y="%s" width="%s" height="%s" fill="%s"/>' % (horizon, w, h - horizon, fl))
    seam = d.lin([(0, wall, 0), (.5, shade(floor, .12), .5), (1, floor, 0)], 0, 0, 0, 1)
    out.append('<rect y="%s" width="%s" height="40" fill="%s"/>' % (horizon - 22, w, seam))
    side = d.lin([(0, "#2b2119", 0), (.7, "#2b2119", 0), (1, "#2b2119", .1)])
    out.append('<rect width="%s" height="%s" fill="%s"/>' % (w, h, side))
    return "".join(out)


def _place(markup, x, y, s=1):
    return '<g transform="translate(%s,%s) scale(%s)">%s</g>' % (x, y, s, markup)


def _wall_shadow(d, shape, x, y, s, dx, dy, op, blur=10):
    if not shape:
        return ""
    return ('<g transform="translate(%s,%s) scale(%s)" opacity="%s" filter="%s"><path d="%s" fill="#3a2a1c"/></g>'
            % (x + dx, y + dy, s, op, d.blur(blur), shape))


def _floor_shadow(d, spec, x, y, s):
    cx, cy, rx, ry, op = spec
    if not op:
        return ""
    return _place(_soft(d, cx, cy, rx, ry, op), x, y, s)


SCENES = {
    # slug: (draw, wall, floor, horizon, x, y, scale, window)
    "fjord-linen-throw": (throw, "#e6ddd0", "#d6cab8", 600, 400, 930, 1.14, True),
    "halo-table-lamp": (lamp, "#d8d0c5", "#cbbfb0", 650, 400, 830, 1.0, False),
    "tern-ceramic-mug": (mugs, "#e3d1c3", "#d4bdaa", 610, 390, 800, 1.42, True),
    "alfama-tile-coasters": (coasters, "#e3dfd5", "#d3cdc0", 600, 380, 800, 1.28, True),
    "oak-serving-board": (board, "#e1dcd2", "#d0c8ba", 640, 380, 690, 1.0, True),
    "stockholm-wool-rug": (rug, "#e8e2d8", "#d6cfc2", 560, 400, 948, 1.05, True),
    "glass-carafe": (carafe, "#dbe0dc", "#c9cfc8", 620, 350, 830, 1.08, True),
    "linen-apron": (apron, "#e4dbcf", "#d4c9b9", 960, 400, 130, 1.0, True),
}

DEFAULT = {
    "fjord-linen-throw": "sand", "halo-table-lamp": "opal", "tern-ceramic-mug": "chalk",
    "alfama-tile-coasters": "azul", "oak-serving-board": "natural", "stockholm-wool-rug": "oat",
    "glass-carafe": "clear", "linen-apron": "sand",
}

# a closer look, as part of the same picture: x, y, width (height is 5/4 of it)
DETAIL = {
    "fjord-linen-throw": (300, 380, 300),
    "halo-table-lamp": (230, 400, 320),
    "tern-ceramic-mug": (170, 470, 300),
    "alfama-tile-coasters": (380, 450, 260),
    "oak-serving-board": (250, 80, 280),
    "stockholm-wool-rug": (440, 600, 300),
    "glass-carafe": (220, 330, 290),
    "linen-apron": (200, 520, 340),
}

# measurements, as the drawing says them
SIZES = {
    "fjord-linen-throw": ("130 cm", "170 cm"),
    "halo-table-lamp": ("Ø 30 cm", "42 cm"),
    "tern-ceramic-mug": ("Ø 8.5 cm", "9.5 cm"),
    "alfama-tile-coasters": ("10 cm", "10 cm"),
    "oak-serving-board": ("24 cm", "58 cm"),
    "stockholm-wool-rug": ("170 cm", "240 cm"),
    "glass-carafe": ("Ø 10 cm", "24 cm"),
    "linen-apron": ("80 cm", "92 cm"),
}


def _extra(slug, d, color):
    """What else stands in the picture."""
    if slug == "oak-serving-board":
        return lemon(d, 560, 850, 1.05) + lemon(d, 640, 930, .8)
    if slug == "stockholm-wool-rug":
        return stool(d, 235, 772, .72)
    return ""


def _before(slug, d, color):
    """What stands behind the product."""
    if slug == "linen-apron":
        rail = d.lin([(0, lit("#c39a6b", .12)), (1, shade("#c39a6b", .2))], 0, 0, 0, 1)
        pegs = ""
        for x in (130, 400, 670):
            pegs += ('<ellipse cx="%s" cy="134" rx="13" ry="13" fill="%s"/>' % (x + 8, shade("#c39a6b", .4))
                     + '<rect x="%s" y="120" width="16" height="28" rx="8" fill="%s"/>' % (x - 8, "#b98d5d")
                     + '<circle cx="%s" cy="134" r="14" fill="%s"/>' % (x - 2, lit("#c39a6b", .1)))
        return ('<rect x="0" y="152" width="800" height="12" fill="#3a2a1c" opacity=".1" filter="%s"/>' % d.blur(5)
                + '<rect x="0" y="112" width="800" height="44" fill="%s"/>' % rail
                + '<rect x="0" y="112" width="800" height="2" fill="#fff" opacity=".4"/>' + pegs)
    return ""


def product(slug, color=None, view="hero"):
    """One picture of a product, as an SVG document."""
    draw, wall, floor, horizon, x, y, s, window = SCENES[slug]
    color = color or DEFAULT[slug]
    d = Defs()
    if view == "dims" and draw is lamp:
        markup, box, fshadow, wshape = lamp(d, color, cord=False, glow=False)
    else:
        markup, box, fshadow, wshape = draw(d, color)
    if view == "dims":
        return _dims(slug, d, markup, box, fshadow)
    body = backdrop(d, W, H, wall, floor, horizon, window)
    body += _before(slug, d, color)
    if wshape:
        if slug == "linen-apron":
            body += _wall_shadow(d, wshape, x, y, s, 22, 16, .18, 9)
        elif slug == "glass-carafe":
            body += _wall_shadow(d, wshape, x, y, s, 70, -40, .07, 14)
        else:
            body += _wall_shadow(d, wshape, x, y, s, 34, 4, .2, 10)
    body += _floor_shadow(d, fshadow, x, y, s)
    body += _place(markup, x, y, s)
    body += _extra(slug, d, color)
    box_attr = "0 0 %s %s" % (W, H)
    if view == "detail":
        bx, by, bw = DETAIL[slug]
        box_attr = "%s %s %s %s" % (bx, by, bw, bw * 1.25)
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="%s" height="%s" '
            'preserveAspectRatio="xMidYMid slice">%s%s</svg>' % (box_attr, W, H, d.svg(), body))


def _dims(slug, d, markup, box, fshadow):
    """The product alone on paper, with its measurements."""
    x0, y0, x1, y1 = box
    if slug in ("fjord-linen-throw", "stockholm-wool-rug"):
        markup, box = _flat(slug, d)
        x0, y0, x1, y1 = box
    bw, bh = x1 - x0, y1 - y0
    s = min(520 / bw, 620 / bh)
    cx, cy = 380, 520
    ox = cx - (x0 + bw / 2) * s
    oy = cy - (y0 + bh / 2) * s
    left, right = ox + x0 * s, ox + x1 * s
    top, bottom = oy + y0 * s, oy + y1 * s
    ink = "#4a4239"
    wl, hl = SIZES[slug]
    out = ['<rect width="%s" height="%s" fill="#f3efe8"/>' % (W, H)]
    out.append('<g transform="translate(%s,%s) scale(%s)">%s</g>' % (ox, oy, s, markup))
    lines = []
    yb = bottom + 56
    lines.append('<path d="M%s,%s L%s,%s M%s,%s L%s,%s M%s,%s L%s,%s" />' % (left, yb, right, yb, left, yb - 9, left, yb + 9, right, yb - 9, right, yb + 9))
    xr = right + 56
    lines.append('<path d="M%s,%s L%s,%s M%s,%s L%s,%s M%s,%s L%s,%s" />' % (xr, top, xr, bottom, xr - 9, top, xr + 9, top, xr - 9, bottom, xr + 9, bottom))
    lines.append('<path d="M%s,%s L%s,%s M%s,%s L%s,%s" stroke-dasharray="3 5" opacity=".6"/>' % (right + 8, top, xr, top, right + 8, bottom, xr, bottom))
    out.append('<g fill="none" stroke="%s" stroke-width="1.6">%s</g>' % (ink, "".join(lines)))
    font = "font-family=\"-apple-system, system-ui, 'Helvetica Neue', Helvetica, Arial, sans-serif\""
    out.append('<rect x="%s" y="%s" width="%s" height="34" rx="17" fill="#f3efe8"/>' % ((left + right) / 2 - 58, yb - 17, 116))
    out.append('<text x="%s" y="%s" %s font-size="22" fill="%s" text-anchor="middle" letter-spacing=".5">%s</text>'
               % ((left + right) / 2, yb + 8, font, ink, wl))
    out.append('<g transform="translate(%s,%s) rotate(-90)"><rect x="-58" y="-17" width="116" height="34" rx="17" fill="#f3efe8"/>'
               '<text x="0" y="8" %s font-size="22" fill="%s" text-anchor="middle" letter-spacing=".5">%s</text></g>'
               % (xr, (top + bottom) / 2, font, ink, hl))
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s" '
            'preserveAspectRatio="xMidYMid slice">%s%s</svg>' % (W, H, W, H, d.svg(), "".join(out)))


def _flat(slug, d):
    """A throw or a rug laid out flat, seen from above."""
    if slug == "fjord-linen-throw":
        w, h, base = 300, 392, "#d5c1a1"
    else:
        w, h, base = 300, 424, "#dcd1bf"
    out = ['<rect x="0" y="0" width="%s" height="%s" rx="4" fill="%s"/>' % (w, h, base)]
    out.append('<rect x="0" y="0" width="%s" height="%s" rx="4" fill="%s"/>' % (w, h, d.weave(shade(base, .5), 5, .12)))
    if slug == "stockholm-wool-rug":
        for t in (.08, .46, .88):
            out.append('<rect x="0" y="%s" width="%s" height="%s" fill="#c8bba5"/>' % (h * t, w, h * .06))
            out.append('<rect x="0" y="%s" width="%s" height="2" fill="#4c4741" opacity=".8"/>' % (h * t + h * .03, w))
    fr = []
    for x in range(4, w - 2, 6):
        fr.append("M%s,%s l0,14 M%s,-1 l0,-14" % (x, h + 1, x))
    out.append('<path d="%s" stroke="%s" stroke-width="2" stroke-linecap="round"/>' % (" ".join(fr), shade(base, .15)))
    return "".join(out), (0, -15, w, h + 15)


# ------------------------------------------------------------------ editorial pictures

def hero():
    """The home page's picture: a sideboard in the evening, the lamp on,
    and a quiet wall on the left for the words."""
    w, h, horizon = 2000, 1000, 700
    d = Defs()
    out = [backdrop(d, w, h, "#ddd4c8", "#cfc3b3", horizon, True)]
    X = 470
    # a print on the wall
    out.append('<g transform="translate(%s,150)">' % (X + 980)
               + '<rect x="10" y="14" width="300" height="380" fill="#3a2a1c" opacity=".14" filter="%s"/>' % d.blur(10)
               + '<rect width="300" height="380" fill="#efe9df"/>'
               '<rect x="16" y="16" width="268" height="348" fill="#f6f2ea"/>'
               '<circle cx="150" cy="168" r="76" fill="#c58a62"/>'
               '<path d="M58,290 C110,250 190,250 242,290" fill="none" stroke="#4e5a44" stroke-width="10" stroke-linecap="round"/>'
               '<rect x="58" y="312" width="184" height="3" fill="#4a4239" opacity=".5"/>'
               '<rect x="0" y="0" width="300" height="380" fill="none" stroke="#b08c62" stroke-width="10"/>'
               "</g>")
    # the sideboard
    oak = "#b88d5f"
    out.append(_place(_soft(d, 0, 0, 700, 40, .32), X + 820, 930))
    top = d.lin([(0, shade(oak, .02)), (1, lit(oak, .2))], 0, 0, 0, 1)
    front = d.lin([(0, lit(oak, .08)), (1, shade(oak, .14))], 0, 0, 0, 1)
    out.append('<path d="M%s,742 L%s,742 L%s,762 L%s,762 Z" fill="%s"/>' % (X + 180, X + 1460, X + 1478, X + 162, top))
    out.append('<rect x="%s" y="762" width="1316" height="150" fill="%s"/>' % (X + 162, front))
    for x in (X + 162 + 1316 / 3, X + 162 + 2 * 1316 / 3):
        out.append('<rect x="%s" y="768" width="2" height="138" fill="%s" opacity=".6"/>' % (x, shade(oak, .4)))
    for x in (X + 162 + 1316 / 6, X + 162 + 1316 / 2, X + 162 + 5 * 1316 / 6):
        out.append('<rect x="%s" y="826" width="64" height="8" rx="4" fill="%s"/>' % (x - 32, shade(oak, .35)))
    out.append('<rect x="%s" y="762" width="1316" height="2" fill="#fff" opacity=".35"/>' % (X + 162))
    leg = d.lin([(0, lit(oak, .05)), (1, shade(oak, .3))])
    for x in (X + 200, X + 1420):
        out.append('<path d="M%s,912 L%s,1000 L%s,1000 L%s,912 Z" fill="%s"/>' % (x, x + 6, x + 22, x + 28, leg))
    # on top: the lamp, books, the carafe, the mugs, a board against the wall
    lm, _, _, _ = lamp(d, "opal", cord=False)
    out.append(_place(lm, X + 420, 752, .92))
    books = ('<rect x="-120" y="-34" width="240" height="34" rx="2" fill="#4e5a44"/>'
             '<rect x="-112" y="-62" width="226" height="28" rx="2" fill="#c58a62"/>'
             '<rect x="-104" y="-84" width="214" height="22" rx="2" fill="#e6dccb"/>'
             '<rect x="-120" y="-34" width="240" height="3" fill="#fff" opacity=".2"/>'
             '<rect x="-112" y="-62" width="226" height="3" fill="#fff" opacity=".25"/>')
    out.append(_place(_soft(d, 40, 0, 170, 14, .3) + books, X + 760, 752))
    mg, _, _, _ = mugs(d, "chalk")
    out.append(_place(mg, X + 760, 668, .62))
    bd, _, _, bshape = board(d, "natural")
    out.append(_wall_shadow(d, bshape, X + 1290, 748, .95, 30, 4, .2))
    out.append(_place(bd, X + 1290, 748, .95))
    cf, _, _, _ = carafe(d, "clear")
    out.append(_place(cf, X + 1060, 752, .82))
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s" '
            'preserveAspectRatio="xMidYMid slice">%s%s</svg>' % (w, h, w, h, d.svg(), "".join(out)))


def collection(name):
    """A tile for a collection: a few of its pieces together."""
    w, h = 900, 1100
    d = Defs()
    if name == "living":
        out = [backdrop(d, w, h, "#ddd5ca", "#cdc1b1", 690, True)]
        th, _, _, _ = throw(d, "moss")
        out.append(_place(_soft(d, 30, 6, 330, 30, .32), 330, 1010, 1.0))
        out.append(_place(th, 330, 1010, 1.0))
        out.append(stool(d, 735, 1040, .95))
        lm, _, _, _ = lamp(d, "opal", cord=False)
        out.append(_place(lm, 735, 1040 - 276 * .95, .62))
    elif name == "kitchen":
        out = [backdrop(d, w, h, "#e2d9cd", "#d2c6b5", 640, True)]
        bd, _, _, bshape = board(d, "natural")
        out.append(_wall_shadow(d, bshape, 600, 760, 1.0, 30, 4, .2))
        out.append(_place(bd, 600, 760, 1.0))
        cf, _, _, _ = carafe(d, "clear")
        out.append(_place(cf, 300, 900, 1.05))
        mg, _, _, _ = mugs(d, "clay")
        out.append(_place(mg, 640, 990, .95))
    else:
        out = [backdrop(d, w, h, "#e6ded2", "#d5cab9", 620, True)]
        rg, _, _, _ = rug(d, "oat")
        out.append(_place(rg, 450, 1060, 1.25))
        th, _, _, _ = throw(d, "sand")
        out.append(_place(_soft(d, 30, 6, 330, 30, .3), 440, 880, .8))
        out.append(_place(th, 440, 880, .8))
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s" '
            'preserveAspectRatio="xMidYMid slice">%s%s</svg>' % (w, h, w, h, d.svg(), "".join(out)))


def story():
    """The workshop: a board, coasters and lemons in the afternoon."""
    w, h = 1200, 900
    d = Defs()
    out = [backdrop(d, w, h, "#d9cfc1", "#c9bba8", 560, True)]
    bd, _, _, bshape = board(d, "smoked")
    out.append(_wall_shadow(d, bshape, 420, 610, .95, 30, 4, .2))
    out.append(_place(bd, 420, 610, .95))
    bd2, _, _, bshape2 = board(d, "natural")
    out.append(_wall_shadow(d, bshape2, 560, 620, .82, 30, 4, .2))
    out.append(_place(bd2, 560, 620, .82))
    co, _, _, _ = coasters(d, "terracotta")
    out.append(_place(co, 860, 780, 1.0))
    out.append(lemon(d, 330, 800, 1.0))
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s" '
            'preserveAspectRatio="xMidYMid slice">%s%s</svg>' % (w, h, w, h, d.svg(), "".join(out)))
