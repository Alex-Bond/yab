"""What Nordbutik sells, in one place: the pages, the bag's script and the
invoices all read it from here."""

PRODUCTS = [
    {
        "slug": "fjord-linen-throw", "name": "Fjord linen throw", "price": 1249,
        "collections": ["textiles", "living"], "badge": "Bestseller", "rating": 4.8, "reviews": 126,
        "colors": [["sand", "Sand", "#d5c1a1"], ["moss", "Moss", "#7b8261"], ["charcoal", "Charcoal", "#4b4a47"]],
        "made": "Woven in Lithuania",
        "blurb": "Stonewashed linen with a hand-knotted fringe, soft from the very first night.",
        "story": "Woven from European flax in a family mill outside Panevėžys, then washed with stones until it drapes like it has always been yours. Heavy enough for October evenings, light enough to keep out all year.",
        "details": ["100% European flax linen, stonewashed", "130 × 170 cm, with a hand-knotted fringe",
                    "Woven in Panevėžys, Lithuania", "OEKO-TEX Standard 100 certified"],
        "care": ["Machine wash at 40°C on a gentle cycle", "Line dry in the shade, or tumble dry low",
                 "No need to iron: the creases are part of it"],
        "dims_alt": "Measured drawing of the Fjord linen throw, 130 by 170 cm",
    },
    {
        "slug": "halo-table-lamp", "name": "Halo table lamp", "price": 1895,
        "collections": ["living"], "badge": "New", "rating": 4.9, "reviews": 41,
        "colors": [["opal", "Opal", "#f3eadb"], ["smoke", "Smoke", "#8f7f6f"]],
        "made": "Mouth-blown in Poland",
        "blurb": "A mouth-blown glass globe on a solid brass foot. Warm, low light for the hour after dinner.",
        "story": "Each globe is blown by hand in Krosno and rests in a turned brass cup, so it sits a little differently on every lamp. The dimmer on the cord takes it from reading light to candlelight.",
        "details": ["Mouth-blown glass, solid brass base", "Ø 30 cm, height 42 cm",
                    "2 m textile cord with an inline dimmer", "E14 LED bulb included, 2700 K"],
        "care": ["Dust the globe with a dry, soft cloth", "Polish the brass now and then, or let it age",
                 "Switch off and let the bulb cool before changing it"],
        "dims_alt": "Measured drawing of the Halo table lamp, 30 cm across and 42 cm tall",
    },
    {
        "slug": "tern-ceramic-mug", "name": "Tern ceramic mug, set of 2", "short": "Tern ceramic mug", "price": 349,
        "collections": ["kitchen"], "badge": "", "rating": 4.7, "reviews": 212,
        "colors": [["chalk", "Chalk", "#ece5d9"], ["fjord", "Fjord", "#8ea4a6"], ["clay", "Clay", "#c4856a"]],
        "made": "Thrown in Portugal",
        "blurb": "Speckled stoneware with a raw clay foot. Holds a proper cup of coffee, and then some.",
        "story": "Thrown on the wheel in a small workshop near Caldas da Rainha and glazed by dipping, so the glaze stops just short of the foot. No two speckles fall in the same place.",
        "details": ["Speckled stoneware, set of 2", "300 ml, Ø 8.5 cm, height 9.5 cm",
                    "Dishwasher and microwave safe", "Thrown and glazed in Portugal"],
        "care": ["Dishwasher safe on a normal cycle", "Avoid sudden changes from very cold to very hot",
                 "The raw foot can mark: lift, don't drag"],
        "dims_alt": "Measured drawing of the Tern ceramic mug, 8.5 cm across and 9.5 cm tall",
    },
    {
        "slug": "alfama-tile-coasters", "name": "Alfama tile coasters, set of 4", "short": "Alfama tile coasters", "price": 279,
        "collections": ["kitchen", "living"], "badge": "", "rating": 4.6, "reviews": 88,
        "colors": [["azul", "Azul", "#2d4c8a"], ["terracotta", "Terracotta", "#a8502f"]],
        "made": "Hand-glazed in Portugal",
        "blurb": "Glazed ceramic tiles on a cork back, after the old azulejos of Lisbon's oldest quarter.",
        "story": "Pressed, painted and fired in Lisbon, with a cork back that keeps them from wandering across the table. Lay them out in a row and the circles meet from tile to tile.",
        "details": ["Glazed ceramic with a cork back, set of 4", "10 × 10 cm, 7 mm thick",
                    "Each tile painted by hand", "Made in Lisbon, Portugal"],
        "care": ["Wipe with a damp cloth", "Not for the dishwasher: the cork doesn't like it",
                 "Let them dry flat"],
        "dims_alt": "Measured drawing of an Alfama tile coaster, 10 by 10 cm",
    },
    {
        "slug": "oak-serving-board", "name": "Oak serving board", "price": 549,
        "collections": ["kitchen"], "badge": "", "rating": 4.9, "reviews": 157,
        "colors": [["natural", "Natural oak", "#cfa472"], ["smoked", "Smoked oak", "#7b5c44"]],
        "made": "Made in Småland, Sweden",
        "blurb": "Solid oak, oiled by hand, for bread, cheese and everything that comes with it.",
        "story": "Cut from FSC-certified Swedish oak by a carpenter in Småland, who rounds every edge by hand and finishes it with linseed oil. It only gets better with use and the occasional oiling.",
        "details": ["Solid FSC-certified oak, oiled", "24 × 58 cm, 2 cm thick",
                    "Hanging hole in the handle", "Made in Småland, Sweden"],
        "care": ["Wash by hand with warm water, dry upright", "Oil with food-safe oil when it looks thirsty",
                 "Never in the dishwasher, never left to soak"],
        "dims_alt": "Measured drawing of the Oak serving board, 24 by 58 cm",
    },
    {
        "slug": "stockholm-wool-rug", "name": "Stockholm wool rug", "price": 4995,
        "collections": ["textiles", "living"], "badge": "", "rating": 4.8, "reviews": 64,
        "colors": [["oat", "Oat", "#dcd1bf"], ["slate", "Slate", "#5f6771"]],
        "made": "Woven in Borås, Sweden",
        "blurb": "A flatweave in undyed wool with quiet stripes, after the rag rugs of old Stockholm kitchens.",
        "story": "Woven on wide looms in Borås from wool that keeps its own lanolin, so spills bead before they sink in. Flat enough for a door to pass over it, heavy enough to stay put.",
        "details": ["100% wool flatweave, undyed stripes", "170 × 240 cm, knotted fringe",
                    "Woven in Borås, Sweden", "Rug pad recommended on hard floors"],
        "care": ["Vacuum without the brush roll", "Blot spills at once with cold water",
                 "Turn it every few months so it wears evenly"],
        "dims_alt": "Measured drawing of the Stockholm wool rug, 170 by 240 cm",
    },
    {
        "slug": "glass-carafe", "name": "Glass carafe 1 L", "price": 429,
        "collections": ["kitchen"], "badge": "New", "rating": 4.7, "reviews": 73,
        "colors": [["clear", "Clear", "#dfe9e6"], ["amber", "Amber", "#c47f34"]],
        "made": "Mouth-blown in Czechia",
        "blurb": "A one-liter carafe in thin, mouth-blown glass, with a tumbler that doubles as its lid.",
        "story": "Blown by hand in northern Bohemia, thin enough to feel light and strong enough for every day. Turn the tumbler upside down on the neck and it keeps the dust out overnight.",
        "details": ["Mouth-blown borosilicate glass", "1 L, Ø 10 cm, height 24 cm, tumbler included",
                    "Dishwasher safe", "Made in Czechia"],
        "care": ["Dishwasher safe on the top rack", "For a clear shine, rinse with a little vinegar",
                 "Not for the stove or the microwave"],
        "dims_alt": "Measured drawing of the Glass carafe, 10 cm across and 24 cm tall",
    },
    {
        "slug": "linen-apron", "name": "Linen apron", "price": 449,
        "collections": ["kitchen", "textiles"], "badge": "", "rating": 4.8, "reviews": 95,
        "colors": [["sand", "Sand", "#d4c1a2"], ["moss", "Moss", "#7c8461"], ["rust", "Rust", "#a45a3d"]],
        "made": "Sewn in Lithuania",
        "blurb": "A full apron in heavy stonewashed linen, with a deep pocket and long ties.",
        "story": "Cut from the same mill's heavier linen and sewn with a neck strap that slides, so it sits right on anyone who borrows it. The pocket is wide enough for a phone, a pen and a recipe.",
        "details": ["100% stonewashed linen, 230 g/m²", "80 × 92 cm, adjustable neck strap",
                    "Divided front pocket, long waist ties", "Sewn in Lithuania"],
        "care": ["Machine wash at 40°C", "Line dry, iron while damp if you like it crisp",
                 "Wash dark colors with like colors"],
        "dims_alt": "Measured drawing of the Linen apron, 80 by 92 cm",
    },
]

BY_SLUG = {p["slug"]: p for p in PRODUCTS}

COLLECTIONS = {
    "all": {"name": "Shop all", "lede": "Everything in the shop right now, made in small batches by people we know by name."},
    "living": {"name": "Living", "lede": "Throws, light and the small things that make a room feel lived in."},
    "kitchen": {"name": "Kitchen & table", "lede": "Stoneware, glass and oak for long breakfasts and longer dinners."},
    "textiles": {"name": "Textiles", "lede": "Linen and wool, woven slowly and washed soft."},
}

FREE_OVER = 1000
DELIVERY = {
    "postnord": {"name": "PostNord", "note": "2 to 4 business days", "price": 59},
    "budbee": {"name": "Budbee Express", "note": "Tomorrow evening, 17:00 to 22:00", "price": 99},
}

COUNTRIES = [
    ("SE", "Sweden"), ("DK", "Denmark"), ("FI", "Finland"), ("NO", "Norway"), ("IS", "Iceland"),
    ("DE", "Germany"), ("NL", "Netherlands"), ("BE", "Belgium"), ("FR", "France"), ("AT", "Austria"),
    ("EE", "Estonia"), ("LV", "Latvia"), ("LT", "Lithuania"), ("PL", "Poland"), ("GB", "United Kingdom"),
]


def color(product, key):
    for c in product["colors"]:
        if c[0] == key:
            return c
    return product["colors"][0]


def short(product):
    return product.get("short") or product["name"]


def for_script():
    """The catalog as the bag's script needs it."""
    return {
        "products": {p["slug"]: {"name": p["name"], "short": short(p), "price": p["price"],
                                 "colors": {c[0]: c[1] for c in p["colors"]}} for p in PRODUCTS},
        "freeOver": FREE_OVER,
        "delivery": {k: v["price"] for k, v in DELIVERY.items()},
    }
