"""Nordbutik's pages, as HTML written on the server: what an agent reads
is there before any script runs. The bag lives in the browser
(localStorage), so the bag and the checkout fill in from there."""
import datetime
import json
from html import escape

catalog = None  # set by routes.py

MIRA = {
    "name": "Mira Lindqvist", "first": "Mira", "email": "mira@lindqvist.studio", "phone": "+46 70 123 45 67",
    "line1": "Södermannagatan 12", "postal": "116 40", "city": "Stockholm", "country": "Sweden",
}


def h(s):
    return escape(str(s), quote=True)


def kr(n):
    return "{:,}".format(int(round(n))).replace(",", " ") + " kr"


def kr2(x):
    whole, frac = "{:,.2f}".format(x).split(".")
    return whole.replace(",", " ") + "," + frac + " kr"


def day(d):
    return "%s, %s %d" % (d.strftime("%A"), d.strftime("%B"), d.day)


def date_long(d):
    return "%s %d, %d" % (d.strftime("%B"), d.day, d.year)


# ------------------------------------------------------------------ icons

ICONS = {
    "search": '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
    "user": '<circle cx="12" cy="8.5" r="3.8"/><path d="M4.5 20c1.2-3.6 4.1-5.5 7.5-5.5s6.3 1.9 7.5 5.5"/>',
    "bag": '<path d="M5.5 8.5h13l-1 11.5h-11z"/><path d="M9 8.5V7a3 3 0 0 1 6 0v1.5"/>',
    "close": '<path d="M6 6l12 12M18 6L6 18"/>',
    "check": '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    "lock": '<rect x="5.5" y="10.5" width="13" height="9.5" rx="2"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/>',
    "truck": '<path d="M3.5 6.5h10v9h-10zM13.5 9.5h4l3 3v3h-7"/><circle cx="7.5" cy="17" r="1.8"/><circle cx="17" cy="17" r="1.8"/>',
    "return": '<path d="M9 7L5 11l4 4"/><path d="M5 11h9.5a4.5 4.5 0 0 1 0 9H11"/>',
    "leaf": '<path d="M5 19c0-8 5-13 14-14 0 9-5 14-13 14z"/><path d="M5 19l7-7"/>',
    "file": '<path d="M7 3.5h7l4.5 4.5v12.5h-11.5z"/><path d="M14 3.5V8h4.5"/><path d="M9.5 13.5h5M9.5 16.5h5"/>',
    "download": '<path d="M12 4v11"/><path d="M7.5 10.5L12 15l4.5-4.5"/><path d="M5 19.5h14"/>',
    "arrow": '<path d="M5 12h14M13 6l6 6-6 6"/>',
    "minus": '<path d="M6 12h12"/>',
    "plus": '<path d="M6 12h12M12 6v12"/>',
    "chevron": '<path d="M7 10l5 5 5-5"/>',
    "pin": '<path d="M12 21s-6.5-6.2-6.5-11a6.5 6.5 0 0 1 13 0c0 4.8-6.5 11-6.5 11z"/><circle cx="12" cy="10" r="2.3"/>',
    "box": '<path d="M4 8l8-4 8 4v8l-8 4-8-4z"/><path d="M4 8l8 4 8-4M12 12v8"/>',
    "card": '<rect x="3.5" y="6" width="17" height="12" rx="2"/><path d="M3.5 10h17"/>',
}


def icon(name, size=20, cls="icon"):
    return ('<svg class="%s" width="%d" height="%d" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">%s</svg>'
            % (cls, size, size, ICONS[name]))


def stars(rating):
    full = int(round(rating))
    out = []
    for i in range(5):
        out.append('<svg%s width="16" height="16" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.2l2.6 5.6 6.1.7-4.5 4.2 1.2 6-5.4-3.1-5.4 3.1 1.2-6-4.5-4.2 6.1-.7z" fill="currentColor"/></svg>'
                   % ("" if i < full else ' class="off"'))
    return '<span class="stars" aria-hidden="true">%s</span>' % "".join(out)


MARK = ('<svg class="mark" width="24" height="24" viewBox="0 0 32 32" aria-hidden="true">'
        '<circle cx="16" cy="16" r="15" fill="#2b2a26"/>'
        '<path d="M16 5.5 L19.6 17.5 L16 15.4 L12.4 17.5 Z" fill="#f4ede1"/>'
        '<path d="M12.4 17.5 L16 15.4 L19.6 17.5 L16 26.5 Z" fill="#c9b08a"/></svg>')

LOGO = '<a class="logo" href="/" aria-label="Nordbutik, home">%s<span>Nordbutik</span></a>' % MARK


# ------------------------------------------------------------------ the frame

def head(title, desc=""):
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<title>%s</title>'
        '<meta name="description" content="%s">'
        '<meta name="theme-color" content="#f7f4ef"><meta name="color-scheme" content="light">'
        '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
        '<link rel="icon" href="/favicon.png" type="image/png" sizes="64x64">'
        '<link rel="apple-touch-icon" href="/apple-touch-icon.png">'
        '<link rel="stylesheet" href="/assets/site.css">'
        '</head>' % (h(title), h(desc or "Linen, wool, oak and glass for slow rooms, made in small batches around the Baltic Sea.")))


NAV = [("all", "/collections/all", "Shop all"), ("living", "/collections/living", "Living"),
       ("kitchen", "/collections/kitchen", "Kitchen & table"), ("textiles", "/collections/textiles", "Textiles"),
       ("about", "/about", "Our story")]


def header(active=None, query=""):
    nav = "".join('<a href="%s"%s>%s</a>' % (href, ' aria-current="page"' if key == active else "", h(label))
                  for key, href, label in NAV)
    return (
        '<div class="announce" role="note"><span>Free delivery on orders over 1 000 kr</span><i></i>'
        '<span>Free returns within 30 days</span><i></i><span>Packed by hand in Stockholm</span></div>'
        '<header class="site-header"><div class="wrap header-row">'
        '<nav class="nav-main" aria-label="Main">%s</nav>'
        '%s'
        '<div class="header-tools">'
        '<form class="search" action="/search" method="get" role="search">'
        '<label class="sr" for="site-search">Search products</label>'
        '<input id="site-search" name="q" type="search" placeholder="Search" value="%s" autocomplete="off">'
        '<button type="submit" aria-label="Search">%s</button></form>'
        '<a class="tool" href="/account/orders" aria-label="Account">%s<span class="tool-word">Account</span></a>'
        '<a class="tool bag-link" href="/bag" aria-label="Bag">%s<span class="tool-word">Bag</span>'
        '<span class="bag-count" data-bag-count hidden>0</span></a>'
        '</div></div></header>' % (nav, LOGO, h(query), icon("search", 16), icon("user"), icon("bag")))


def footer():
    cols = [
        ("Shop", [("/collections/all", "Shop all"), ("/collections/living", "Living"),
                  ("/collections/kitchen", "Kitchen & table"), ("/collections/textiles", "Textiles")]),
        ("Help", [("/help#delivery", "Delivery"), ("/help#returns", "Returns"), ("/help#care", "Care guides"),
                  ("/account/orders", "Your orders"), ("/help#contact", "Contact us")]),
        ("Nordbutik", [("/about", "Our story"), ("/about#makers", "Our makers"), ("/about#studio", "Visit the studio")]),
    ]
    links = "".join('<div class="foot-col"><h4>%s</h4>%s</div>' % (
        h(title), "".join('<a href="%s">%s</a>' % (href, h(label)) for href, label in items)) for title, items in cols)
    return (
        '<footer class="site-footer"><div class="wrap">'
        '<div class="foot-top">'
        '<div class="letters"><h3>Letters from the studio</h3>'
        '<p>New pieces, visits to our makers and the occasional recipe. Once a month, never more.</p>'
        '<form class="letters-form" data-letters><label class="sr" for="letters-email">Email address</label>'
        '<input id="letters-email" type="email" name="letters" placeholder="Your email address">'
        '<button class="btn btn-dark" type="submit">Subscribe</button></form>'
        '<p class="letters-done" hidden>Thank you. Your first letter arrives in November.</p></div>'
        '<div class="foot-cols">%s</div></div>'
        '<div class="foot-bottom"><span>© 2026 Nordbutik AB, Stockholm</span>'
        '<span class="foot-pay"><b>Visa</b><b>Mastercard</b><b>Amex</b><b>Invoice</b></span>'
        '<span>Sweden (SEK kr)</span></div>'
        '</div></footer>' % links)


def script_tag():
    return ('<script>window.NB = %s;</script><script src="/assets/site.js"></script>'
            % json.dumps(catalog.for_script(), ensure_ascii=False))


def page(title, body, active=None, query="", desc="", cls=""):
    return (head(title, desc) + '<body class="%s">' % cls + header(active, query)
            + '<main id="main">%s</main>' % body + footer() + drawer() + script_tag() + "</body></html>")


def drawer():
    return (
        '<div class="drawer-scrim" data-drawer-scrim hidden></div>'
        '<aside class="drawer" role="dialog" aria-modal="false" aria-labelledby="drawer-title" data-drawer hidden>'
        '<div class="drawer-head"><p id="drawer-title">%s Added to your bag</p>'
        '<button type="button" class="icon-btn" data-drawer-close aria-label="Close">%s</button></div>'
        '<div class="drawer-item" data-drawer-item></div>'
        '<p class="drawer-free" data-drawer-free></p>'
        '<div class="drawer-actions"><a class="btn btn-line" href="/bag" data-drawer-view>View bag</a>'
        '<a class="btn btn-dark" href="/checkout">Checkout</a></div>'
        '<button type="button" class="drawer-keep" data-drawer-close>Continue shopping</button>'
        '</aside>' % (icon("check", 20), icon("close", 16)))


# ------------------------------------------------------------------ pieces

def media(slug, color, view="hero"):
    if view == "dims":
        return "/media/%s-dims.svg" % slug
    if view == "detail":
        return "/media/%s-%s-detail.svg" % (slug, color)
    return "/media/%s-%s.svg" % (slug, color)


def card(p, eager=False):
    first = p["colors"][0]
    dots = "".join('<i style="--c:%s" title="%s"></i>' % (c[2], h(c[1])) for c in p["colors"])
    badge = '<span class="badge">%s</span>' % h(p["badge"]) if p["badge"] else ""
    lazy = "" if eager else ' loading="lazy"'
    return (
        '<a class="card" href="/p/%s">'
        '<div class="card-media"><img src="%s" alt="%s in %s"%s>'
        '<img class="card-alt" src="%s" alt=""%s>%s</div>'
        '<div class="card-row"><span class="card-name">%s</span><span class="money">%s</span></div>'
        '<div class="card-sub"><span class="dots">%s</span><span>%d colors</span></div>'
        '</a>' % (p["slug"], media(p["slug"], first[0]), h(p["name"]), h(first[1]), lazy,
                  media(p["slug"], first[0], "detail"), lazy, badge, h(p["name"]), kr(p["price"]),
                  dots, len(p["colors"])))


def grid(products, eager=4):
    return '<div class="grid">%s</div>' % "".join(card(p, i < eager) for i, p in enumerate(products))


# ------------------------------------------------------------------ pages

def home():
    products = catalog.PRODUCTS
    order = ["fjord-linen-throw", "halo-table-lamp", "tern-ceramic-mug", "glass-carafe",
             "stockholm-wool-rug", "oak-serving-board", "alfama-tile-coasters", "linen-apron"]
    products = [catalog.BY_SLUG[s] for s in order]
    tiles = ""
    for key, art_name in (("living", "living"), ("kitchen", "kitchen"), ("textiles", "textiles")):
        c = catalog.COLLECTIONS[key]
        n = len([p for p in catalog.PRODUCTS if key in p["collections"]])
        tiles += ('<a class="tile" href="/collections/%s"><span class="tile-media"><img src="/media/collection-%s.svg" alt="" loading="lazy"></span>'
                  '<span class="tile-text"><span class="tile-name">%s</span><span class="tile-count">%d pieces %s</span></span></a>'
                  % (key, art_name, h(c["name"]), n, icon("arrow", 16)))
    body = (
        '<section class="hero">'
        '<img class="hero-img" src="/media/hero.svg" alt="The Halo table lamp, Tern mugs, a glass carafe and an oak board on a sideboard">'
        '<div class="wrap hero-copy">'
        '<p class="eyebrow">The autumn edit</p>'
        '<h1>Made for<br>slow evenings</h1>'
        '<p class="hero-lede">Linen, wool, oak and glass, made in small batches by makers around the Baltic Sea.</p>'
        '<div class="hero-actions"><a class="btn btn-dark" href="/collections/all">Shop the autumn edit</a>'
        '<a class="btn btn-quiet" href="/about#makers">Meet our makers</a></div>'
        '</div></section>'
        '<section class="wrap section">'
        '<div class="section-head"><h2>Shop by room</h2><a class="more" href="/collections/all">Shop all %s</a></div>'
        '<div class="tiles">%s</div></section>'
        '<section class="wrap section">'
        '<div class="section-head"><h2>New this autumn</h2><a class="more" href="/collections/all">View all 8 pieces %s</a></div>'
        '%s</section>'
        '<section class="wrap section story-band">'
        '<div class="story-media"><img src="/media/story.svg" alt="Oak boards, tile coasters and lemons in the workshop" loading="lazy"></div>'
        '<div class="story-copy"><p class="eyebrow">How we work</p>'
        '<h2>Made slowly, by people we know by name</h2>'
        '<p>We work with eleven small workshops around the Baltic Sea and a few friends further south. '
        'We visit every one of them, buy in small batches, and pay for the time things take.</p>'
        '<ul class="values">'
        '<li>%s<div><b>Natural materials</b><span>Linen, wool, oak, stoneware and glass. Nothing that needs a warning label.</span></div></li>'
        '<li>%s<div><b>Free delivery over 1 000 kr</b><span>Packed by hand in our Stockholm studio, usually the same day.</span></div></li>'
        '<li>%s<div><b>30 days to change your mind</b><span>Free returns from any PostNord service point.</span></div></li>'
        '</ul><a class="btn btn-line" href="/about">Read our story</a></div></section>'
        % (icon("arrow", 16), tiles, icon("arrow", 16), grid(products), icon("leaf", 24), icon("truck", 24), icon("return", 24)))
    return page("Nordbutik · Scandinavian design for slow rooms", body, active=None)


def collection(key):
    c = catalog.COLLECTIONS.get(key)
    if not c:
        return None
    products = catalog.PRODUCTS if key == "all" else [p for p in catalog.PRODUCTS if key in p["collections"]]
    chips = "".join('<a class="chip" href="/collections/%s"%s>%s</a>' % (k, ' aria-current="page"' if k == key else "", h(v["name"]))
                    for k, v in catalog.COLLECTIONS.items())
    body = (
        '<div class="wrap">'
        '<nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a><span>/</span><span aria-current="page">%s</span></nav>'
        '<header class="list-head"><h1>%s</h1><p>%s</p></header>'
        '<div class="list-bar"><div class="chips">%s</div><span class="list-count">%d pieces</span></div>'
        '%s</div>' % (h(c["name"]), h(c["name"]), h(c["lede"]), chips, len(products), grid(products, 8)))
    return page("%s · Nordbutik" % c["name"], body, active=key)


def search(q):
    words = [w for w in q.lower().split() if w]
    found = []
    for p in catalog.PRODUCTS:
        hay = " ".join([p["name"], p["blurb"], p["made"], " ".join(c[1] for c in p["colors"]),
                        " ".join(catalog.COLLECTIONS[k]["name"] for k in p["collections"]),
                        " ".join(p["details"])]).lower()
        if all(w in hay or (w.endswith("s") and w[:-1] in hay) for w in words):
            found.append(p)
    if not words:
        found = list(catalog.PRODUCTS)
    if words and found:
        say = '%d %s for <q>%s</q>' % (len(found), "result" if len(found) == 1 else "results", h(q))
    elif words:
        say = 'No results for <q>%s</q>' % h(q)
    else:
        say = "Search the shop"
    empty = ""
    if words and not found:
        empty = ('<div class="empty"><p>Nothing matches that yet. Try <a href="/search?q=linen">linen</a>, '
                 '<a href="/search?q=oak">oak</a> or <a href="/search?q=glass">glass</a>, or browse everything.</p>'
                 '<a class="btn btn-dark" href="/collections/all">Shop all</a></div>')
    body = (
        '<div class="wrap">'
        '<header class="list-head search-head"><h1>%s</h1>'
        '<form class="search-big" action="/search" method="get" role="search">'
        '<label class="sr" for="search-page">Search products</label>'
        '<input id="search-page" name="q" type="search" value="%s" placeholder="Linen, oak, glass…" autocomplete="off">'
        '<button class="btn btn-dark" type="submit">Search</button></form></header>'
        '%s%s</div>' % (say, h(q), grid(found, 8) if found else "", empty))
    return page("Search: %s · Nordbutik" % q if q else "Search · Nordbutik", body, query=q)


def product(slug):
    p = catalog.BY_SLUG.get(slug)
    if not p:
        return None
    first = p["colors"][0]
    coll = p["collections"][0]
    swatches = "".join(
        '<label class="swatch" title="%s"><input type="radio" name="color" value="%s" data-name="%s"%s>'
        '<span class="swatch-dot" style="--c:%s"></span><span class="sr">%s</span></label>'
        % (h(c[1]), c[0], h(c[1]), " checked" if i == 0 else "", c[2], h(c[1])) for i, c in enumerate(p["colors"]))
    thumbs = "".join(
        '<button type="button" class="thumb%s" data-view="%s" aria-label="%s"%s><img src="%s" alt=""></button>'
        % (" is-on" if v == "hero" else "", v, label, ' aria-pressed="true"' if v == "hero" else ' aria-pressed="false"',
           media(slug, first[0], v)) for v, label in (("hero", "Show the product"), ("detail", "Show a closer look"), ("dims", "Show the measurements")))
    details = "".join("<li>%s</li>" % h(x) for x in p["details"])
    care = "".join("<li>%s</li>" % h(x) for x in p["care"])
    related = [x for x in catalog.PRODUCTS if x["slug"] != slug and set(x["collections"]) & set(p["collections"])][:4]
    if len(related) < 4:
        related += [x for x in catalog.PRODUCTS if x["slug"] != slug and x not in related][:4 - len(related)]
    guide = "/p/%s/care-guide.pdf" % slug
    body = (
        '<div class="wrap">'
        '<nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a><span>/</span>'
        '<a href="/collections/%s">%s</a><span>/</span><span aria-current="page">%s</span></nav>'
        '<div class="pdp" data-product="%s">'
        '<section class="gallery" aria-label="Pictures of the %s">'
        '<div class="gallery-main"><img data-main src="%s" alt="%s in %s"></div>'
        '<div class="thumbs">%s</div></section>'
        '<section class="buy">'
        '<p class="eyebrow">%s · %s</p>'
        '<h1>%s</h1>'
        '<a class="rating" href="#reviews">%s<span>%s</span><span class="rating-count">%d reviews</span></a>'
        '<p class="price money">%s</p>'
        '<p class="tax">Tax included. Free delivery over 1 000 kr.</p>'
        '<p class="lede">%s</p>'
        '<form class="add-form" action="/bag" method="get" data-add>'
        '<fieldset class="swatches"><legend>Color: <b data-color-name>%s</b></legend><div class="swatch-row">%s</div></fieldset>'
        '<div class="buy-row">'
        '<div class="qty"><button type="button" data-qty="-1" aria-label="Decrease quantity">%s</button>'
        '<label class="sr" for="qty">Quantity</label><input id="qty" name="qty" type="number" inputmode="numeric" value="1" min="1" max="10">'
        '<button type="button" data-qty="1" aria-label="Increase quantity">%s</button></div>'
        '<button type="submit" class="btn btn-dark btn-add">Add to bag</button></div></form>'
        '<ul class="assure"><li><i class="dot-ok"></i>In stock, ships within 1 to 2 business days</li>'
        '<li>%s Free delivery over 1 000 kr, free 30-day returns</li></ul>'
        '<div class="accordion">'
        '<details open><summary>Details %s</summary><div class="acc-body"><p>%s</p><ul>%s</ul></div></details>'
        '<details><summary>Care %s</summary><div class="acc-body"><ul>%s</ul>'
        '<p>Everything we know about looking after it is in the care guide.</p></div></details>'
        '<details><summary>Delivery &amp; returns %s</summary><div class="acc-body">'
        '<p>PostNord delivers to your door or nearest service point in 2 to 4 business days, free over 1 000 kr and 59 kr below. '
        'In Stockholm, Budbee Express brings it tomorrow evening for 99 kr.</p>'
        '<p>Changed your mind? Return it within 30 days, free of charge, from any PostNord service point.</p></div></details>'
        '</div>'
        '<a class="file-link" href="%s" download="Nordbutik care guide, %s.pdf">%s<span><b>Download care guide (PDF)</b>'
        '<small>%s · PDF · 410 KB</small></span>%s</a>'
        '</section></div>'
        '<section class="section reviews" id="reviews"><div class="section-head"><h2>What people say</h2>'
        '<span class="rating big">%s<span>%s out of 5</span><span class="rating-count">%d reviews</span></span></div>'
        '<div class="quotes">%s</div></section>'
        '<section class="section"><div class="section-head"><h2>Pairs well with</h2></div>%s</section>'
        '</div>'
        % (coll, h(catalog.COLLECTIONS[coll]["name"]), h(p["name"]), slug, h(p["name"]),
           media(slug, first[0]), h(p["name"]), h(first[1]), thumbs,
           h(catalog.COLLECTIONS[coll]["name"]), h(p["made"]), h(p["name"]),
           stars(p["rating"]), p["rating"], p["reviews"], kr(p["price"]), h(p["blurb"]),
           h(first[1]), swatches, icon("minus", 16), icon("plus", 16), icon("truck", 16),
           icon("chevron", 16), h(p["story"]), details, icon("chevron", 16), care, icon("chevron", 16),
           guide, h(p["name"]), icon("file", 24), h(p["name"]), icon("download", 20),
           stars(p["rating"]), p["rating"], p["reviews"], quotes(slug), grid(related, 0)))
    return page("%s · Nordbutik" % p["name"], body, active=coll, desc=p["blurb"])


QUOTES = {
    "fjord-linen-throw": [("Annika S.", "Gothenburg", "Softer than I expected and it gets better with every wash. The sand color is exactly as pictured."),
                          ("Jonas E.", "Uppsala", "Lives on our sofa now. Heavy enough to feel cozy, light enough for summer nights."),
                          ("Lea M.", "Copenhagen", "The fringe is beautifully done. Bought a second one in moss for the bedroom.")],
    "halo-table-lamp": [("Henrik B.", "Stockholm", "The glow is lovely, warm and even. The dimmer makes it perfect for evenings."),
                        ("Sofia L.", "Malmö", "Heavier and better made than lamps twice the price. The brass is real."),
                        ("Karin T.", "Oslo", "Arrived beautifully packed. Every guest asks where it is from.")],
}
GENERIC_QUOTES = [("Elin W.", "Stockholm", "Beautifully made and packed with care. You can tell someone thought about every detail."),
                  ("Mats H.", "Västerås", "Exactly as described, and it arrived in two days. Already ordered another as a gift."),
                  ("Ingrid P.", "Helsinki", "The quality is wonderful. It looks even better in our kitchen than in the pictures.")]


def quotes(slug):
    out = []
    for name, city, text in QUOTES.get(slug, GENERIC_QUOTES):
        out.append('<figure class="quote">%s<blockquote>%s</blockquote><figcaption>%s <span>%s · Verified buyer</span></figcaption></figure>'
                   % (stars(5), h(text), h(name), h(city)))
    return "".join(out)


def bag():
    body = (
        '<div class="wrap bag-page">'
        '<header class="list-head"><h1>Your bag</h1></header>'
        '<div class="bag-layout" data-bag-root>'
        '<noscript><p>Your bag needs JavaScript to show what is in it.</p></noscript>'
        '</div></div>')
    return page("Your bag · Nordbutik", body, cls="is-bag")


def checkout(values=None, errors=None):
    v = values or {}
    e = errors or {}

    def field(name, label, auto, kind="text", extra="", hint="", cls="", value_key=None):
        val = v.get(value_key or name, "")
        err = e.get(name)
        return ('<div class="field %s%s"><label for="f-%s">%s</label>'
                '<input id="f-%s" name="%s" type="%s" autocomplete="%s"%s value="%s"%s>%s%s</div>'
                % (cls, " has-error" if err else "", name, label, name, name, kind, auto, extra, h(val),
                   ' aria-invalid="true" aria-describedby="err-%s"' % name if err else "",
                   '<p class="field-hint">%s</p>' % hint if hint else "",
                   '<p class="field-error" id="err-%s">%s</p>' % (name, h(err)) if err else
                   '<p class="field-error" id="err-%s" hidden></p>' % name))
    country = v.get("country", "SE")
    options = "".join('<option value="%s"%s>%s</option>' % (code, " selected" if code == country else "", h(name))
                      for code, name in catalog.COUNTRIES)
    method = v.get("delivery", "postnord")
    alert = ""
    if e:
        alert = ('<div class="co-alert" role="alert">%s<div><b>Please check your details</b>'
                 '<span>A few fields need another look before we can take payment.</span></div></div>' % icon("close", 20))
    body = (
        '<div class="co">'
        '<div class="co-main"><div class="co-inner">'
        '<nav class="co-steps" aria-label="Checkout steps"><a href="/bag">Bag</a>%s<span aria-current="step">Details &amp; payment</span>%s<span class="muted">Confirmation</span></nav>'
        '%s'
        '<form id="checkout" class="co-form" action="/checkout" method="post" novalidate>'
        '<section class="co-section" aria-labelledby="h-contact"><div class="co-head"><h2 id="h-contact">Contact</h2>'
        '<a href="/account/orders">Sign in</a></div>'
        '%s'
        '<label class="check"><input type="checkbox" name="news" value="yes"%s><span class="box">%s</span>Email me with news and offers</label>'
        '</section>'
        '<section class="co-section" aria-labelledby="h-delivery"><div class="co-head"><h2 id="h-delivery">Delivery</h2></div>'
        '%s%s%s'
        '<div class="row">%s%s</div>'
        '<div class="field"><label for="f-country">Country/Region</label>'
        '<div class="select"><select id="f-country" name="country" autocomplete="country">%s</select>%s</div></div>'
        '%s'
        '</section>'
        '<section class="co-section" aria-labelledby="h-method"><div class="co-head"><h2 id="h-method">Delivery method</h2></div>'
        '<div class="methods">'
        '<label class="method"><input type="radio" name="delivery" value="postnord"%s><span class="radio"></span>'
        '<span class="method-text"><b>PostNord</b><small>2 to 4 business days, to your door or a service point</small></span>'
        '<span class="method-price" data-ship-price="postnord">Free</span></label>'
        '<label class="method"><input type="radio" name="delivery" value="budbee"%s><span class="radio"></span>'
        '<span class="method-text"><b>Budbee Express</b><small>Tomorrow evening, 17:00 to 22:00</small></span>'
        '<span class="method-price money">99 kr</span></label>'
        '</div></section>'
        '<section class="co-section" aria-labelledby="h-pay"><div class="co-head"><h2 id="h-pay">Payment</h2></div>'
        '<p class="co-note">%s All transactions are secure and encrypted.</p>'
        '<div class="paybox">'
        '<div class="paybox-head"><span class="radio on"></span><b>Credit or debit card</b>'
        '<span class="brands" aria-hidden="true"><i class="brand visa">VISA</i><i class="brand mc">Mastercard</i><i class="brand amex">AMEX</i></span></div>'
        '<div class="paybox-body">'
        '<div class="field field-card%s"><label for="f-cardnumber">Card number</label>'
        '<div class="input-wrap"><input id="f-cardnumber" name="cardnumber" type="text" inputmode="numeric" autocomplete="cc-number" '
        'placeholder="1234 1234 1234 1234" maxlength="23" value="%s"%s><span class="card-brand" data-brand aria-live="polite"></span>%s</div>%s</div>'
        '<div class="row">%s%s</div>'
        '%s'
        '</div></div>'
        '<label class="check"><input type="checkbox" name="billing_same" value="yes" checked><span class="box">%s</span>Use delivery address as billing address</label>'
        '</section>'
        '<input type="hidden" name="bag" value="%s" data-bag-field>'
        '<button type="submit" class="btn btn-dark btn-pay" data-pay>%s<span data-pay-label>Pay</span></button>'
        '<p class="co-fine">Your card is charged when you press Pay. You can return anything within 30 days.</p>'
        '</form>'
        '<footer class="co-foot"><a href="/help#returns">Refund policy</a><a href="/help#delivery">Delivery</a>'
        '<a href="/help#contact">Contact</a><a href="/about">Terms of service</a></footer>'
        '</div></div>'
        '<aside class="co-side" aria-label="Order summary"><div class="co-inner" data-summary>'
        '<h2 class="sr">Order summary</h2>'
        '<div class="sum-items" data-sum-items></div>'
        '<form class="discount" data-discount><label class="sr" for="discount">Discount code</label>'
        '<input id="discount" name="discount" type="text" placeholder="Discount code" autocomplete="off">'
        '<button type="submit" class="btn btn-line">Apply</button></form>'
        '<p class="discount-msg" data-discount-msg hidden></p>'
        '<dl class="sum-lines"><div><dt>Subtotal</dt><dd class="money" data-sum-subtotal></dd></div>'
        '<div><dt>Delivery</dt><dd class="money" data-sum-ship></dd></div>'
        '<div class="sum-total"><dt>Total</dt><dd><small>SEK</small> <span class="money" data-sum-total></span></dd></div></dl>'
        '<p class="sum-tax" data-sum-tax></p>'
        '<div class="sum-assure"><p>%s<span>Free returns within 30 days</span></p><p>%s<span>Packed by hand in Stockholm</span></p></div>'
        '</div></aside>'
        '</div>'
        % (icon("chevron", 16, "icon rot"), icon("chevron", 16, "icon rot"), alert,
           field("email", "Email", "email", "email", ' required spellcheck="false"'),
           " checked" if v.get("news") else "", icon("check", 16),
           field("name", "Full name", "name", "text", " required"),
           field("address1", "Address", "address-line1", "text", " required"),
           field("address2", "Apartment, suite, etc. (optional)", "address-line2", "text"),
           field("postal_code", "Postal code", "postal-code", "text", ' required inputmode="numeric"', cls="field-postal"),
           field("city", "City", "address-level2", "text", " required"),
           options, icon("chevron", 16),
           field("phone", "Phone", "tel", "tel", " required", hint="For delivery updates by text"),
           " checked" if method != "budbee" else "", " checked" if method == "budbee" else "",
           icon("lock", 16),
           " has-error" if e.get("cardnumber") else "", h(v.get("cardnumber", "")),
           ' aria-invalid="true"' if e.get("cardnumber") else "", icon("lock", 16, "icon in-lock"),
           '<p class="field-error" id="err-cardnumber"%s>%s</p>' % ("" if e.get("cardnumber") else " hidden", h(e.get("cardnumber", ""))),
           field("exp", "Expiration date", "cc-exp", "text", ' required inputmode="numeric" placeholder="MM / YY" maxlength="7"'),
           field("cvc", "Security code", "cc-csc", "text", ' required inputmode="numeric" placeholder="CVC" maxlength="4"', hint="3 digits on the back of the card"),
           field("ccname", "Name on card", "cc-name", "text", " required"),
           icon("check", 16), h(v.get("bag", "")), icon("lock", 16)
           , icon("return", 16), icon("box", 16)))
    return (head("Checkout · Nordbutik", "Checkout") + '<body class="is-checkout">'
            '<header class="co-header"><div class="co-header-row">%s'
            '<span class="co-secure">%s Secure checkout</span>'
            '<a class="tool bag-link" href="/bag" aria-label="Back to bag">%s<span class="bag-count" data-bag-count hidden>0</span></a>'
            '</div></header><main id="main">%s</main>%s</body></html>'
            % (LOGO, icon("lock", 16), icon("bag"), body, script_tag()))


def keep_dates(text):
    """A date stays on one line: "Monday, October 5" never breaks before its 5."""
    import re
    return re.sub(r"((?:[A-Z][a-z]+day, )?(?:January|February|March|April|May|June|July|August|September|October|November|December) \d{1,2}(?:, \d{4})?)",
                  r'<span class="nw">\1</span>', text)


def order_page(order, fresh=False):
    items = "".join(
        '<div class="sum-item"><div class="sum-thumb"><img src="%s" alt=""><span class="sum-qty">%d</span></div>'
        '<div class="sum-name"><b>%s</b><small>%s</small></div><span class="money">%s</span></div>'
        % (media(i["slug"], i["color"]), i["qty"], h(i["name"]), h(i["color_name"]), kr(i["price"] * i["qty"]))
        for i in order["items"])
    placed = order["placed"]
    method = catalog.DELIVERY[order["delivery"]]
    addr = order["address"]
    lines = [addr["name"], addr["line1"]] + ([addr["line2"]] if addr.get("line2") else []) + \
            ["%s %s" % (addr["postal"], addr["city"]), addr["country"]]
    addr_html = "<br>".join(h(x) for x in lines)
    delivered = order.get("delivered")
    if delivered:
        status_title = "Delivered %s" % date_long(delivered)
        status_line = "Signed for at the door. We hope it feels at home."
        steps_done = 4
    else:
        status_title = order["eta"]
        status_line = ("We'll text %s when it leaves our studio, with a link to follow it." % order["phone"]) if order.get("phone") else "We'll email you a link to follow it when it leaves our studio."
        steps_done = 1
    steps = ""
    for i, (label, when) in enumerate((("Confirmed", placed.strftime("%b %d, %H:%M")), ("Packed", ""), ("On its way", ""), ("Delivered", ""))):
        if delivered:
            when = {0: placed.strftime("%b %d"), 1: (placed + datetime.timedelta(days=1)).strftime("%b %d"),
                    2: (placed + datetime.timedelta(days=2)).strftime("%b %d"), 3: delivered.strftime("%b %d")}[i]
        steps += '<li class="%s"><span class="step-dot">%s</span><b>%s</b><small>%s</small></li>' % (
            "done" if i < steps_done else "", icon("check", 16) if i < steps_done else "", label, h(when))
    head_title = ("Thank you, %s!" % order["first"]) if fresh else ("Order #%s" % order["number"])
    eyebrow = ("Order #%s is confirmed" % order["number"]) if fresh else ("Placed %s" % date_long(placed))
    confirm_card = ""
    if fresh:
        confirm_card = ('<div class="oc-card oc-confirm"><div class="parcel">%s</div><div><h2>Your order is confirmed</h2>'
                        '<p>We have sent a confirmation to <b>%s</b>. Your pieces are being wrapped in our Stockholm studio.</p></div></div>'
                        % (PARCEL, h(order["email"])))
    body = (
        '<div class="co oc">'
        '<div class="co-main"><div class="co-inner">'
        '<header class="oc-head"><span class="oc-check">%s</span><div><p class="eyebrow">%s</p><h1>%s</h1></div></header>'
        '%s'
        '<div class="oc-card"><div class="oc-status"><div><p class="oc-label">%s</p><h2>%s</h2><p>%s</p></div>'
        '<span class="oc-truck">%s</span></div>'
        '<ol class="oc-steps">%s</ol></div>'
        '<div class="oc-card oc-details"><h2>Order details</h2><div class="oc-grid">'
        '<div><h3>Contact</h3><p>%s</p></div>'
        '<div><h3>Payment</h3><p>%s ending in %s<br><span class="money">%s</span></p></div>'
        '<div><h3>Delivery address</h3><p>%s</p></div>'
        '<div><h3>Delivery method</h3><p>%s<br>%s</p></div>'
        '</div></div>'
        '<div class="oc-actions"><a class="btn btn-dark" href="/collections/all">Continue shopping</a>'
        '<a class="btn btn-line" href="/account/orders">View your orders</a>'
        '<a class="text-link" href="/account/orders/%s/invoice.pdf" download="Nordbutik invoice %s.pdf">%s Download invoice</a></div>'
        '</div></div>'
        '<aside class="co-side" aria-label="Order summary"><div class="co-inner">'
        '<div class="sum-items">%s</div>'
        '<dl class="sum-lines"><div><dt>Subtotal</dt><dd class="money">%s</dd></div>'
        '<div><dt>Delivery</dt><dd class="money">%s</dd></div>'
        '<div class="sum-total"><dt>Total</dt><dd><small>SEK</small> <span class="money">%s</span></dd></div></dl>'
        '<p class="sum-tax">Including %s in taxes</p>'
        '</div></aside></div>'
        % (icon("check", 24), h(eyebrow), h(head_title), confirm_card,
           "Delivered" if delivered else "Estimated delivery", keep_dates(h(status_title)), h(status_line), icon("truck", 24),
           steps, h(order["email"]), h(order["brand"]), h(order["last4"]), kr(order["total"]), addr_html,
           h(method["name"]), "Free" if order["shipping"] == 0 else kr(order["shipping"]),
           order["number"], order["number"], icon("download", 16),
           items, kr(order["subtotal"]), "Free" if order["shipping"] == 0 else kr(order["shipping"]), kr(order["total"]),
           kr2(order["total"] * 0.2)))
    title = "Order #%s confirmed · Nordbutik" % order["number"] if fresh else "Order #%s · Nordbutik" % order["number"]
    return (head(title) + '<body class="is-checkout is-order"%s>' % (' data-placed="%s"' % order["number"] if fresh else "")
            + '<header class="co-header"><div class="co-header-row">%s<span class="co-secure">%s Order #%s</span>'
              '<a class="tool bag-link" href="/bag" aria-label="Bag">%s<span class="bag-count" data-bag-count hidden>0</span></a></div></header>'
            % (LOGO, icon("box", 16), order["number"], icon("bag"))
            + '<main id="main">%s</main>%s</body></html>' % (body, script_tag()))


PARCEL = ('<svg viewBox="0 0 120 100" width="120" height="100" aria-hidden="true">'
          '<ellipse cx="62" cy="88" rx="46" ry="7" fill="#3a2a1c" opacity=".12"/>'
          '<path d="M18 38 L60 22 L102 38 L102 78 L60 94 L18 78 Z" fill="#d9bf98"/>'
          '<path d="M60 54 L102 38 L102 78 L60 94 Z" fill="#c6a679"/>'
          '<path d="M18 38 L60 54 L60 94 L18 78 Z" fill="#e3cca8"/>'
          '<path d="M18 38 L60 22 L102 38 L60 54 Z" fill="#ecdcc0"/>'
          '<path d="M39 30 L81 46 L81 86" fill="none" stroke="#8a6a44" stroke-width="3"/>'
          '<path d="M39 30 L81 46" stroke="#f6eddd" stroke-width="1" opacity=".6"/>'
          '<path d="M76 40 C70 30 58 30 60 37 C62 42 72 42 76 40 C80 34 92 30 92 37 C92 43 82 43 76 40 Z" fill="none" stroke="#8a6a44" stroke-width="2.4"/>'
          '<rect x="27" y="58" width="22" height="12" rx="1.5" fill="#f7f1e6" transform="skewY(20) translate(0,-10)"/>'
          '</svg>')


def account_frame(active, inner, title):
    links = [("orders", "/account/orders", "Orders"), ("addresses", "/account/addresses", "Addresses"),
             ("profile", "/account/profile", "Profile")]
    nav = "".join('<a href="%s"%s>%s</a>' % (href, ' aria-current="page"' if key == active else "", label)
                  for key, href, label in links)
    body = (
        '<div class="wrap account">'
        '<aside class="acc-side"><p class="acc-hello">Hi, %s</p><p class="acc-mail">%s</p>'
        '<nav aria-label="Account">%s<a href="/" class="acc-out">Sign out</a></nav></aside>'
        '<section class="acc-main">%s</section></div>' % (h(MIRA["first"]), h(MIRA["email"]), nav, inner))
    return page(title, body)


def orders_page(orders):
    cards = ""
    for o in orders:
        thumbs = "".join('<img src="%s" alt="%s, %s">' % (media(i["slug"], i["color"]), h(i["name"]), h(i["color_name"]))
                         for i in o["items"])
        names = ", ".join("%s%s" % ("%d × " % i["qty"] if i["qty"] > 1 else "", i["name"]) for i in o["items"])
        if o.get("delivered"):
            pill = '<span class="pill ok">Delivered %s</span>' % h(o["delivered"].strftime("%B %d").replace(" 0", " "))
        else:
            pill = '<span class="pill">Confirmed, arriving %s</span>' % h(o["eta_short"])
        cards += (
            '<article class="order-card" aria-labelledby="o-%s">'
            '<header><div><h2 id="o-%s">Order #%s</h2><p>Placed %s · %d %s · <span class="money">%s</span></p></div>%s</header>'
            '<div class="order-body"><div class="order-thumbs">%s</div><p class="order-names">%s</p></div>'
            '<footer><a class="btn btn-line btn-sm" href="/order/%s">View order</a>'
            '<a class="file-link small" href="/account/orders/%s/invoice.pdf" download="Nordbutik invoice %s.pdf">%s'
            '<span><b>Download invoice</b><small>PDF · 400 KB</small></span></a></footer>'
            '</article>' % (o["number"], o["number"], o["number"], date_long(o["placed"]), sum(i["qty"] for i in o["items"]),
                            "item" if sum(i["qty"] for i in o["items"]) == 1 else "items", kr(o["total"]), pill,
                            thumbs, h(names), o["number"], o["number"], o["number"], icon("file", 16)))
    inner = ('<header class="acc-head"><h1>Orders</h1><p>%d orders since June. Invoices are PDFs you can keep for your records.</p></header>%s'
             % (len(orders), cards))
    return account_frame("orders", inner, "Your orders · Nordbutik")


def addresses_page():
    inner = ('<header class="acc-head"><h1>Addresses</h1><p>Where we send your orders.</p></header>'
             '<div class="addr-card"><span class="pill">Default</span><p><b>%s</b><br>%s<br>%s %s<br>%s<br>%s</p></div>'
             % (h(MIRA["name"]), h(MIRA["line1"]), h(MIRA["postal"]), h(MIRA["city"]), h(MIRA["country"]), h(MIRA["phone"])))
    return account_frame("addresses", inner, "Addresses · Nordbutik")


def profile_page():
    inner = ('<header class="acc-head"><h1>Profile</h1><p>How we reach you.</p></header>'
             '<dl class="profile"><div><dt>Name</dt><dd>%s</dd></div><div><dt>Email</dt><dd>%s</dd></div>'
             '<div><dt>Phone</dt><dd>%s</dd></div><div><dt>Letters from the studio</dt><dd>Subscribed</dd></div></dl>'
             % (h(MIRA["name"]), h(MIRA["email"]), h(MIRA["phone"])))
    return account_frame("profile", inner, "Profile · Nordbutik")


def help_page():
    guides = "".join(
        '<a class="file-link" href="/p/%s/care-guide.pdf" download="Nordbutik care guide, %s.pdf">%s<span><b>%s</b><small>Care guide · PDF</small></span>%s</a>'
        % (p["slug"], h(p["name"]), icon("file", 24), h(p["name"]), icon("download", 20)) for p in catalog.PRODUCTS)
    body = (
        '<div class="wrap prose-page">'
        '<header class="list-head"><h1>Help</h1><p>Delivery, returns and looking after what you bought.</p></header>'
        '<section id="delivery"><h2>Delivery</h2><p>We pack every order by hand in our Stockholm studio, usually the same day. '
        'PostNord delivers in 2 to 4 business days, free over 1 000 kr and 59 kr below. In Stockholm, Budbee Express delivers '
        'the next evening between 17:00 and 22:00 for 99 kr.</p></section>'
        '<section id="returns"><h2>Returns</h2><p>You have 30 days to change your mind. Print the label from your order page and '
        'drop the parcel at any PostNord service point. Returns are free, and we refund within 3 days of receiving them.</p></section>'
        '<section id="care"><h2>Care guides</h2><p>Everything we know about keeping each piece at its best, as PDFs to keep.</p>'
        '<div class="guide-list">%s</div></section>'
        '<section id="contact"><h2>Contact us</h2><p>Write to us from your order page, or visit the studio at Krukmakargatan 21 '
        'on Södermalm, Thursday to Saturday, 11:00 to 17:00.</p></section>'
        '</div>' % guides)
    return page("Help · Nordbutik", body)


def about_page():
    makers = [("Linas & Rūta", "Panevėžys, Lithuania", "Linen, washed with stones"),
              ("Huta Krosno", "Krosno, Poland", "Mouth-blown glass"),
              ("Oficina Barro", "Caldas da Rainha, Portugal", "Stoneware, thrown on the wheel"),
              ("Snickeri Ek", "Småland, Sweden", "Oak, turned and oiled"),
              ("Väveriet", "Borås, Sweden", "Wool, woven on wide looms"),
              ("Azulejaria Alfama", "Lisbon, Portugal", "Tiles, painted by hand")]
    cards = "".join('<li><b>%s</b><span>%s</span><small>%s</small></li>' % (h(a), h(b), h(c)) for a, b, c in makers)
    body = (
        '<div class="wrap prose-page about">'
        '<header class="list-head"><p class="eyebrow">Our story</p><h1>A small shop for slow rooms</h1>'
        '<p>Nordbutik began in 2019 as a table at the Christmas market in Hornstull. We sold linen we had found in Lithuania and '
        'mugs from a friend in Portugal. Today we work with eleven workshops, and we still know every one of them by name.</p></header>'
        '<img class="about-img" src="/media/hero.svg" alt="">'
        '<section id="makers"><h2>Our makers</h2><ul class="makers">%s</ul></section>'
        '<section id="studio"><h2>Visit the studio</h2><p>Krukmakargatan 21, Södermalm, Stockholm. Thursday to Saturday, 11:00 to 17:00. '
        'Come for the pieces, stay for a coffee.</p></section>'
        '</div>' % cards)
    return page("Our story · Nordbutik", body, active="about")


def not_found():
    body = ('<div class="wrap notfound"><p class="eyebrow">404</p><h1>We couldn\'t find that page</h1>'
            '<p>It may have moved, or it was never here. Try the search, or start from the shop.</p>'
            '<form class="search-big" action="/search" method="get" role="search"><label class="sr" for="nf-q">Search products</label>'
            '<input id="nf-q" name="q" type="search" placeholder="Linen, oak, glass…"><button class="btn btn-dark" type="submit">Search</button></form>'
            '<p><a class="text-link" href="/collections/all">Shop all %s</a></p></div>' % icon("arrow", 16))
    return page("Page not found · Nordbutik", body)
