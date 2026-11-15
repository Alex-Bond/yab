"""Orbit, a product analytics app: sign in with a password and a code
mailed to Mira, sign up, and the signed-in home for the project Tern Web.

Pages are templates in _t/ ({{name}} escaped, {{{name}}} raw, {{> part}}
for a shared piece); everything under assets/ is served as it is.
"""
import base64
import hashlib
import hmac
import html
import json
import re
import secrets
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATES = HERE / "_t"
KEY = b"orbit-demo-sessions-are-not-secret"
MIRA = {"email": "mira@ternlabs.com", "name": "Mira Lindqvist"}
SENDER = "Orbit <security@orbit.localtest.me>"
CODE_LIFE = 10 * 60
COOKIE = "Path=/; HttpOnly; SameSite=Lax"

LOCK = threading.Lock()
CHALLENGES = {}  # token: {"email", "name", "codes": [[code, at]], "at"}


# ---------------------------------------------------------------- pages

def esc(value):
    return html.escape(str(value), quote=True)


def render(template, **values):
    text = (TEMPLATES / (template + ".html")).read_text()
    for _ in range(4):
        text, count = re.subn(r"\{\{>\s*([\w-]+)\s*\}\}",
                              lambda m: (TEMPLATES / (m.group(1) + ".html")).read_text(), text)
        if not count:
            break
    text = re.sub(r"\{\{\{\s*(\w+)\s*\}\}\}", lambda m: str(values.get(m.group(1), "")), text)
    return re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: esc(values.get(m.group(1), "")), text)


def alert(message):
    if not message:
        return ""
    return ('<div class="alert" role="alert"><svg viewBox="0 0 20 20" aria-hidden="true">'
            '<circle cx="10" cy="10" r="7.25"/><path d="M10 6.5v4M10 13.4v.1"/></svg><span>%s</span></div>' % esc(message))


def initials(name):
    parts = [p for p in re.split(r"\s+", name.strip()) if p]
    if not parts:
        return "?"
    if len(parts) == 1:
        return parts[0][:2].upper()
    return (parts[0][0] + parts[-1][0]).upper()


def first_name(name):
    return (name.strip().split() or [""])[0]


# ---------------------------------------------------------------- cookies

def sign(data):
    raw = base64.urlsafe_b64encode(json.dumps(data, separators=(",", ":")).encode()).decode().rstrip("=")
    mac = hmac.new(KEY, raw.encode(), hashlib.sha256).hexdigest()[:24]
    return raw + "." + mac


def unsign(value):
    try:
        raw, mac = value.rsplit(".", 1)
        want = hmac.new(KEY, raw.encode(), hashlib.sha256).hexdigest()[:24]
        if not hmac.compare_digest(mac, want):
            return None
        return json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, TypeError):
        return None


def user_of(req):
    data = unsign(req.cookies.get("orbit_session", ""))
    if not data or not data.get("e"):
        return None
    return {"email": data["e"], "name": data.get("n") or data["e"].split("@")[0]}


def session_cookie(email, name):
    return "orbit_session=%s; %s; Max-Age=%d" % (sign({"e": email, "n": name}), COOKIE, 30 * 86400)


def challenge_of(req):
    token = req.cookies.get("orbit_challenge", "")
    with LOCK:
        found = CHALLENGES.get(token)
        if found and time.time() - found["at"] > 3600:
            CHALLENGES.pop(token, None)
            found = None
    return token, found


# ---------------------------------------------------------------- the code

def new_code():
    return str(secrets.randbelow(900000) + 100000)


def spaced(code):
    return code[:3] + " " + code[3:]


def mail_code(ctx, email, name, code):
    """The letter Orbit sends: a plain part a mail reader takes the code
    from, and a page with the code set large."""
    first = first_name(name) or "there"
    text = ("Your Orbit verification code is %s.\n\n"
            "Enter it on the sign-in page to finish signing in to Orbit. It expires in 10 minutes.\n\n"
            "If you didn't try to sign in, you can ignore this email. Orbit will never ask you for this code.\n\n"
            "Orbit Analytics") % spaced(code)
    try:
        logo = "data:image/png;base64," + base64.b64encode((HERE / "favicon.png").read_bytes()).decode()
    except OSError:
        logo = ""
    page = render("mail-code", first=first, email=email, code=spaced(code), logo=logo)
    ctx.mail(SENDER, "Your Orbit sign-in code", text, html=page)


def start_challenge(ctx, email, name):
    token = secrets.token_urlsafe(18)
    code = new_code()
    now = time.time()
    with LOCK:
        CHALLENGES[token] = {"email": email, "name": name, "codes": [[code, now]], "at": now}
    mail_code(ctx, email, name, code)
    return token


def code_from(form):
    joined = re.sub(r"\D", "", form.get("code", ""))
    if len(joined) != 6:
        joined = re.sub(r"\D", "", "".join(form.get("code%d" % i, "") for i in range(1, 7)))
    return joined


def check_code(found, code):
    """'ok', 'expired' or 'wrong'. Every code mailed for this sign-in works
    while it is fresh, the newest and the ones before it, and so does a
    fresh one mailed to the same person for a sign-in started again."""
    now = time.time()
    for sent, at in found["codes"]:
        if hmac.compare_digest(sent, code):
            return "ok" if now - at <= CODE_LIFE else "expired"
    with LOCK:
        others = [c for c in CHALLENGES.values() if c is not found and c["email"] == found["email"]]
    for other in others:
        for sent, at in other["codes"]:
            if hmac.compare_digest(sent, code) and now - at <= CODE_LIFE:
                return "ok"
    return "wrong"


# ---------------------------------------------------------------- routes

def page(ctx, template, status=200, **values):
    return ctx.html(render(template, **values), status)


def not_found(ctx):
    return ctx.html((HERE / "404.html").read_text(), 404)


def login_page(ctx, email="", error="", status=200):
    return page(ctx, "login", status, email=email, alert=alert(error),
                email_invalid="true" if error else "false")


def handle(req, ctx):
    path = req.path.rstrip("/") or "/"
    method = "GET" if req.method == "HEAD" else req.method

    if path.startswith("/_t"):
        return not_found(ctx)

    if path == "/":
        user = user_of(req)
        if not user:
            return ctx.redirect("/login")
        return page(ctx, "home", name=user["name"], first=first_name(user["name"]),
                    email=user["email"], initials=initials(user["name"]))

    if path == "/login":
        if method != "POST":
            return login_page(ctx)
        email = req.form.get("email", "").strip()
        password = req.form.get("password", "")
        if not email or not password:
            return login_page(ctx, email, "Enter your email and password to sign in.")
        if email.lower() != MIRA["email"]:
            return login_page(ctx, email, "No Orbit account uses that email.")
        token = start_challenge(ctx, MIRA["email"], MIRA["name"])
        return ctx.redirect("/verify", cookies="orbit_challenge=%s; %s" % (token, COOKIE))

    if path == "/verify":
        token, found = challenge_of(req)
        if not found:
            return ctx.redirect("/login")
        if method != "POST":
            notice = "We sent you a new code." if req.query.get("resent") else ""
            return page(ctx, "verify", email=found["email"], alert="", notice=notice)
        code = code_from(req.form)
        result = check_code(found, code) if len(code) == 6 else "short"
        if result == "ok":
            with LOCK:
                CHALLENGES.pop(token, None)
            return ctx.redirect("/", cookies=[session_cookie(found["email"], found["name"]),
                                              "orbit_challenge=; Path=/; Max-Age=0"])
        message = {
            "short": "Enter all six digits of the code.",
            "expired": "That code has expired. Send a new one and try again.",
        }.get(result, "That code isn't right. Check the latest email from Orbit and try again.")
        return page(ctx, "verify", 200, email=found["email"], alert=alert(message), notice="")

    if path == "/verify/resend" and method == "POST":
        token, found = challenge_of(req)
        wants_json = "json" in (req.headers.get("Accept") or "")
        if not found:
            return ctx.json({"ok": False}, 401) if wants_json else ctx.redirect("/login")
        code = new_code()
        with LOCK:
            found["codes"].append([code, time.time()])
        mail_code(ctx, found["email"], found["name"], code)
        return ctx.json({"ok": True, "email": found["email"]}) if wants_json else ctx.redirect("/verify?resent=1")

    if path == "/signup":
        if method != "POST":
            return page(ctx, "signup", name="", email="", alert="")
        name = re.sub(r"\s+", " ", req.form.get("name", "")).strip()
        email = req.form.get("email", "").strip()
        password = req.form.get("password", "")
        error = ""
        if not name or not email or not password:
            error = "Fill in your name, work email and a password."
        elif "@" not in email:
            error = "Enter a work email like you@company.com."
        elif len(password) < 8:
            error = "Use at least 8 characters for your password."
        if error:
            return page(ctx, "signup", 200, name=name, email=email, alert=alert(error))
        return ctx.redirect("/welcome", cookies=session_cookie(email.lower(), name))

    if path == "/welcome":
        user = user_of(req)
        if not user:
            return ctx.redirect("/signup")
        key = "pk_" + hashlib.sha1(user["email"].encode()).hexdigest()[:14]
        return page(ctx, "welcome", name=user["name"], first=first_name(user["name"]),
                    email=user["email"], initials=initials(user["name"]), key=key)

    if path == "/forgot":
        if method != "POST":
            return page(ctx, "forgot", sent="false", email="")
        return page(ctx, "forgot", sent="true", email=req.form.get("email", "").strip())

    if path == "/logout":
        return ctx.redirect("/login", cookies="orbit_session=; Path=/; Max-Age=0")

    return None
