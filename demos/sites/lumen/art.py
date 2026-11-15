"""Lumen's pictures: each event's square cover and the map of where it is."""
import math
import random

FONT = "font-family=\"-apple-system, system-ui, 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif\""
SERIF = "font-family=\"ui-serif, 'New York', 'Iowan Old Style', Georgia, serif\""


def _svg(w, h, body, defs=""):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d">'
            '<defs>%s</defs>%s</svg>' % (w, h, w, h, defs, body))


def design_systems_night():
    defs = (
        '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1b1640"/><stop offset=".55" stop-color="#231a4d"/><stop offset="1" stop-color="#120f2b"/></linearGradient>'
        '<radialGradient id="glow" cx=".72" cy=".3" r=".55"><stop offset="0" stop-color="#ff9a6b" stop-opacity=".9"/><stop offset=".35" stop-color="#c25cff" stop-opacity=".55"/><stop offset="1" stop-color="#6d5dfc" stop-opacity="0"/></radialGradient>'
        '<radialGradient id="glow2" cx=".15" cy=".95" r=".5"><stop offset="0" stop-color="#3dd6c6" stop-opacity=".45"/><stop offset="1" stop-color="#3dd6c6" stop-opacity="0"/></radialGradient>'
        '<linearGradient id="btn" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffb37a"/><stop offset="1" stop-color="#ff7aa8"/></linearGradient>'
        '<linearGradient id="card" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff" stop-opacity=".14"/><stop offset="1" stop-color="#ffffff" stop-opacity=".05"/></linearGradient>'
        '<pattern id="grid" width="32" height="32" patternUnits="userSpaceOnUse"><path d="M32 0H0V32" fill="none" stroke="#ffffff" stroke-opacity=".06" stroke-width="1"/></pattern>'
    )
    b = ['<rect width="800" height="800" fill="url(#bg)"/>', '<rect width="800" height="800" fill="url(#grid)"/>',
         '<rect width="800" height="800" fill="url(#glow)"/>', '<rect width="800" height="800" fill="url(#glow2)"/>']
    # a card component, floating
    b.append('<g transform="translate(408,92) rotate(-6)">'
             '<rect width="300" height="196" rx="22" fill="url(#card)" stroke="#ffffff" stroke-opacity=".28"/>'
             '<circle cx="40" cy="42" r="16" fill="#ffffff" fill-opacity=".85"/>'
             '<rect x="68" y="32" width="120" height="9" rx="4.5" fill="#ffffff" fill-opacity=".8"/>'
             '<rect x="68" y="48" width="78" height="7" rx="3.5" fill="#ffffff" fill-opacity=".4"/>'
             '<rect x="24" y="82" width="252" height="7" rx="3.5" fill="#ffffff" fill-opacity=".35"/>'
             '<rect x="24" y="98" width="214" height="7" rx="3.5" fill="#ffffff" fill-opacity=".35"/>'
             '<rect x="24" y="138" width="112" height="36" rx="18" fill="url(#btn)"/>'
             '<rect x="48" y="152" width="64" height="8" rx="4" fill="#2a1840" fill-opacity=".75"/>'
             '<rect x="148" y="138" width="112" height="36" rx="18" fill="none" stroke="#ffffff" stroke-opacity=".5"/>'
             '<rect x="172" y="152" width="64" height="8" rx="4" fill="#ffffff" fill-opacity=".6"/>'
             '</g>')
    # a toggle, a slider, a checkbox
    b.append('<g transform="translate(96,128)">'
             '<rect width="88" height="48" rx="24" fill="#7c6cff"/><circle cx="64" cy="24" r="18" fill="#fff"/>'
             '<rect x="0" y="80" width="200" height="6" rx="3" fill="#ffffff" fill-opacity=".25"/>'
             '<rect x="0" y="80" width="128" height="6" rx="3" fill="#ffb37a"/><circle cx="128" cy="83" r="13" fill="#fff"/>'
             '<rect x="0" y="122" width="34" height="34" rx="9" fill="#3dd6c6"/>'
             '<path d="M8 139l7 7 12-14" fill="none" stroke="#10302c" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>'
             '<rect x="48" y="134" width="96" height="9" rx="4.5" fill="#ffffff" fill-opacity=".55"/>'
             '</g>')
    # color tokens
    for i, c in enumerate(("#6d5dfc", "#c25cff", "#ff7aa8", "#ffb37a", "#ffe29a", "#3dd6c6")):
        b.append('<circle cx="%d" cy="352" r="22" fill="%s"/>' % (118 + i * 56, c))
    b.append('<text x="96" y="400" %s font-size="15" fill="#ffffff" fill-opacity=".55" letter-spacing="1.5">COLOR · TYPE · SPACE · MOTION</text>' % FONT)
    # spacing scale
    x = 470
    for w in (6, 10, 14, 20, 28, 40, 56):
        b.append('<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="#ffffff" fill-opacity=".22"/>' % (x, 386 - w, w, w))
        x += w + 10
    # type specimen
    b.append('<text x="604" y="560" %s font-size="150" font-weight="700" fill="#ffffff" fill-opacity=".1" letter-spacing="-6">Aa</text>' % FONT)
    # the title
    b.append('<text x="64" y="560" %s font-size="76" font-weight="700" fill="#ffffff" letter-spacing="-3">Design</text>' % FONT)
    b.append('<text x="64" y="640" %s font-size="76" font-weight="700" fill="#ffffff" letter-spacing="-3">Systems Night</text>' % FONT)
    b.append('<text x="66" y="700" %s font-size="22" font-weight="500" fill="#ffffff" fill-opacity=".72">Stockholm · Vol. 07</text>' % FONT)
    b.append('<text x="66" y="748" %s font-size="16" fill="#ffffff" fill-opacity=".5">Figure Community Stockholm × Tern Labs</text>' % FONT)
    return _svg(800, 800, "".join(b), defs)


def _poster(bg, title_lines, sub, ink="#ffffff", art="", defs="", size=80, serif=False, y0=560):
    b = [bg, art]
    fam = SERIF if serif else FONT
    for i, line in enumerate(title_lines):
        b.append('<text x="64" y="%d" %s font-size="%d" font-weight="%s" fill="%s" letter-spacing="%s">%s</text>'
                 % (y0 + i * (size + 4), fam, size, "500" if serif else "700", ink, "-1" if serif else "-3", line))
    b.append('<text x="66" y="%d" %s font-size="22" font-weight="500" fill="%s" fill-opacity=".72">%s</text>'
             % (y0 + len(title_lines) * (size + 4) + 32, FONT, ink, sub))
    return _svg(800, 800, "".join(b), defs)


def founders_and_fika():
    defs = ('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffe3c2"/><stop offset="1" stop-color="#ffb38a"/></linearGradient>'
            '<radialGradient id="sun" cx=".7" cy=".32" r=".3"><stop offset="0" stop-color="#fff6d6"/><stop offset="1" stop-color="#fff6d6" stop-opacity="0"/></radialGradient>')
    art = ('<rect width="800" height="800" fill="url(#sun)"/>'
           '<g transform="translate(520,250)" fill="none" stroke="#7a3b1d" stroke-width="7" stroke-linecap="round">'
           '<path d="M-90 -10 h160 v70 a80 80 0 0 1 -160 0 z" fill="#fff7ea"/>'
           '<path d="M70 10 a34 34 0 0 1 0 68" />'
           '<path d="M-40 -40 c-12 -20 12 -30 0 -50 M0 -40 c-12 -20 12 -30 0 -50 M40 -40 c-12 -20 12 -30 0 -50" stroke-width="5" opacity=".6"/>'
           '</g>'
           '<g transform="translate(250,250)" fill="none" stroke="#7a3b1d" stroke-width="6" stroke-linecap="round">'
           '<circle r="70" fill="#e8a46a"/><path d="M0 0 m-8 0 a8 8 0 1 1 16 0 a20 20 0 1 1 -40 0 a34 34 0 1 1 68 0 a48 48 0 1 1 -96 0"/></g>')
    return _poster('<rect width="800" height="800" fill="url(#bg)"/>', ["Founders", "&amp; Fika"], "AI tooling breakfast · Vasastan",
                   "#3b1a0c", art, defs)


def sunday_run_club():
    defs = '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#d9f99d"/><stop offset="1" stop-color="#34d399"/></linearGradient>'
    art = ('<path d="M-20 360 C120 200 260 420 380 260 S620 120 820 220" fill="none" stroke="#065f46" stroke-width="18" stroke-linecap="round" stroke-dasharray="2 30" opacity=".75"/>'
           '<circle cx="640" cy="170" r="70" fill="#fef9c3"/>'
           '<path d="M0 470 C200 420 420 520 800 440 L800 800 L0 800 Z" fill="#10b981" opacity=".35"/>')
    return _poster('<rect width="800" height="800" fill="url(#bg)"/>', ["Sunday", "Run Club"], "7 km around Djurgården · coffee after",
                   "#053b2c", art, defs)


def creative_coding_14():
    rnd = random.Random(14)
    lines = []
    for i in range(46):
        y = 40 + i * 11
        amp = 18 + 40 * math.sin(i / 7)
        pts = []
        for x in range(0, 821, 20):
            pts.append("%d,%.1f" % (x, y + amp * math.sin(x / 90 + i / 5) + rnd.uniform(-1.5, 1.5)))
        lines.append('<polyline points="%s" fill="none" stroke="hsl(%d, 90%%, 65%%)" stroke-width="1.6" opacity=".7"/>' % (" ".join(pts), 180 + i * 3))
    art = '<g opacity=".9">%s</g>' % "".join(lines)
    return _poster('<rect width="800" height="800" fill="#0b1220"/>', ["Creative", "Coding #14"], "Shaders, plotters and noise · Kungsholmen",
                   "#ffffff", art + '<rect y="470" width="800" height="330" fill="#0b1220" opacity=".55"/>')


def product_people_mixer():
    defs = '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fbcfe8"/><stop offset="1" stop-color="#c4b5fd"/></linearGradient>'
    art = ('<g style="mix-blend-mode:multiply" opacity=".9"><circle cx="300" cy="250" r="150" fill="#f472b6"/>'
           '<circle cx="470" cy="230" r="150" fill="#fb923c"/><circle cx="390" cy="360" r="150" fill="#a78bfa"/></g>')
    return _poster('<rect width="800" height="800" fill="url(#bg)"/>', ["Product People", "autumn mixer"], "PMs, designers, engineers · Östermalm",
                   "#2e1065", art, defs, size=70)


def type_tuesdays():
    art = ('<text x="420" y="430" %s font-size="420" fill="#b45309" opacity=".9" text-anchor="middle">Åa</text>' % SERIF
           + '<rect x="64" y="470" width="672" height="2" fill="#3f2a14" opacity=".4"/>')
    return _poster('<rect width="800" height="800" fill="#f5ecdc"/>', ["Type Tuesdays"], "Swedish type, 1900 to now · Gamla stan",
                   "#3f2a14", art, size=74, serif=True, y0=580)


COVERS = {
    "design-systems-night": design_systems_night, "founders-and-fika": founders_and_fika,
    "sunday-run-club": sunday_run_club, "creative-coding-14": creative_coding_14,
    "product-people-mixer": product_people_mixer, "type-tuesdays": type_tuesdays,
}


def cover(slug):
    fn = COVERS.get(slug)
    return fn() if fn else None


def map_svg(label="Hyllie Studio"):
    """Södermalm, drawn: water to the north, blocks, a park, the pin."""
    w, h = 720, 300
    rnd = random.Random(21)
    b = ['<rect width="%d" height="%d" fill="#f2efe9"/>' % (w, h)]
    # water: Riddarfjärden and Saltsjön along the top
    b.append('<path d="M0 0 H720 V58 C640 74 560 52 470 70 C380 88 300 60 210 78 C130 94 60 80 0 92 Z" fill="#cfe3ef"/>')
    b.append('<path d="M0 92 C60 80 130 94 210 78 C300 60 380 88 470 70 C560 52 640 74 720 58" fill="none" stroke="#b9d5e6" stroke-width="2"/>')
    # a park
    b.append('<path d="M520 170 h120 a14 14 0 0 1 14 14 v62 a14 14 0 0 1 -14 14 h-120 a14 14 0 0 1 -14 -14 v-62 a14 14 0 0 1 14 -14 z" fill="#d7ead0"/>')
    b.append('<circle cx="560" cy="205" r="9" fill="#bcdcae"/><circle cx="600" cy="230" r="11" fill="#bcdcae"/><circle cx="620" cy="196" r="7" fill="#bcdcae"/>')
    # streets
    streets = ["M0 140 C200 130 420 150 720 132", "M0 214 C240 206 480 222 720 210", "M0 276 C220 270 500 284 720 272",
               "M96 92 L84 300", "M232 84 L236 300", "M372 80 L360 300", "M486 72 L500 300", "M690 60 L680 300"]
    for i, d in enumerate(streets):
        b.append('<path d="%s" fill="none" stroke="#ffffff" stroke-width="%d" stroke-linecap="round"/>' % (d, 13 if i in (1, 4) else 8))
    b.append('<path d="M0 214 C240 206 480 222 720 210" fill="none" stroke="#fde68a" stroke-width="5" stroke-linecap="round"/>')
    # street names
    b.append('<text x="40" y="207" %s font-size="11" fill="#9a8f7f" letter-spacing=".5">Götgatan</text>' % FONT)
    b.append('<text x="520" y="290" %s font-size="11" fill="#9a8f7f" letter-spacing=".5">Bondegatan</text>' % FONT)
    b.append('<text x="250" y="130" %s font-size="11" fill="#9a8f7f" letter-spacing=".5">Folkungagatan</text>' % FONT)
    b.append('<text x="560" y="40" %s font-size="11" fill="#7aa3bc" letter-spacing="1.2">SALTSJÖN</text>' % FONT)
    b.append('<text x="74" y="44" %s font-size="11" fill="#7aa3bc" letter-spacing="1.2">RIDDARFJÄRDEN</text>' % FONT)
    b.append('<text x="548" y="222" %s font-size="10" fill="#7fa36f" letter-spacing=".4">Vitabergsparken</text>' % FONT)
    # the pin
    px, py = 420, 176
    b.append('<circle cx="%d" cy="%d" r="34" fill="#6d5dfc" opacity=".14"/>' % (px, py))
    b.append('<circle cx="%d" cy="%d" r="18" fill="#6d5dfc" opacity=".22"/>' % (px, py))
    b.append('<path d="M%d %d c-14 -16 -22 -27 -22 -38 a22 22 0 0 1 44 0 c0 11 -8 22 -22 38 z" fill="#131517"/>' % (px, py))
    b.append('<circle cx="%d" cy="%d" r="8" fill="#ffffff"/>' % (px, py - 38))
    b.append('<g transform="translate(%d,%d)"><rect x="0" y="-15" width="%d" height="30" rx="15" fill="#ffffff" stroke="#e7e3dc"/>'
             '<text x="14" y="5" %s font-size="13" font-weight="600" fill="#131517">%s</text></g>'
             % (px + 30, py - 52, 26 + 7.4 * len(label), FONT, label))
    return _svg(w, h, "".join(b))
