#!/usr/bin/env python3
"""The sites a demo world visits, and the mail it reads, on this Mac.

    python3 demos/server.py              in front, until ^C
    python3 demos/server.py --check      say what answers where, then quit

One process, three ports on 127.0.0.1:

    8800  the made-up sites, told apart by host (sites/<name>/site.json):
          nordbutik.localtest.me, daybook.localtest.me, ledger.localtest.me,
          lumen.localtest.me, orbit.localtest.me, paper.localtest.me, and
          localhost:8800 for Roundtable, the call. *.localtest.me is public
          DNS that answers 127.0.0.1, so Yab keeps these in its history the
          way it keeps real sites (it leaves localhost out).
    5173  Tern's own site, in the making: the page Measure and the
          Developer Tools card are shown on.
    8795  Gmail's API as Yab's mail calls it (evals/mail/fake_gmail.py),
          Mira's two mailboxes: /work/gmail/v1/users/me/ (mira@ternlabs.com)
          and /personal/gmail/v1/users/me/ (mira@lindqvist.studio);
          POST /__demo/reset fills both afresh.

A site is a folder of files, served as they are (`/checkout` finds
checkout.html), and may add a routes.py with `handle(req, ctx)` for what
files can't do: a sign-in, a code mailed to Mira, a slow download. Every
site also answers /__demo/state.json, the world's clock and its people, so
a page can say "in 12 minutes" the way the world was built.
"""
import argparse
import importlib.util
import json
import mimetypes
import os
import sys
import threading
import time
import traceback
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
SITES = HERE / "sites"
# The made-up Gmail is the mail eval's (evals/mail/fake_gmail.py); a copy of
# this folder made for the scene launchers carries its own beside it.
sys.path.insert(0, str(HERE.parent / "evals" / "mail"))
sys.path.insert(0, str(HERE))
from fake_gmail import FakeGmail, b64  # noqa: E402

PORTS = {"sites": 8800, "dev": 5173, "mail": 8795}
STATE = Path(os.environ.get("YAB_DEMO_STATE", str(Path.home() / "Library/Caches/yab-demo/state.json")))

mimetypes.add_type("text/vtt", ".vtt")
mimetypes.add_type("application/javascript", ".js")
mimetypes.add_type("application/javascript", ".mjs")
mimetypes.add_type("image/svg+xml", ".svg")
mimetypes.add_type("font/woff2", ".woff2")


def state():
    """What the world builder wrote: when it was built, Mira, the day's times."""
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {"built": time.time()}


# ---------------------------------------------------------------- the mail

class Inbox(FakeGmail):
    """FakeGmail with letters that have a page of their own (`html`); Cc
    and other headers go through as FakeGmail takes them."""

    def add(self, thread, sender, subject, body, labels, to=None, ago=0, bulk=False, record=True, html=None, **headers):
        mid = super().add(thread, sender, subject, body, labels, to=to, ago=ago, bulk=bulk, record=record, **headers)
        if html:
            with self.lock:
                self.messages[mid]["page"] = html
        return mid

    def html(self, m):
        return m.get("page") or super().html(m)

    def reset(self, me, letters):
        with self.lock:
            self.me = me
            self.messages = {}
            self.records = []
            self.count = 0
            self.history = 100
            self.oldest = 0
            self.labels = {}
            self.calls = []
        for letter in letters:
            self.add(record=False, **letter)


# Mira's two mailboxes, each its own Gmail as far as Yab can tell: work at
# /work/gmail/v1/users/me/, personal at /personal/gmail/v1/users/me/.
INBOXES = {"work": Inbox(me="mira@ternlabs.com"), "personal": Inbox(me="mira@lindqvist.studio")}
INBOX = INBOXES["work"]


def fill_inbox():
    """Mira's inbox afresh, from persona.py as it is now (read again each
    time, so an edit there shows in the next world without a restart)."""
    try:
        import persona
        importlib.reload(persona)
    except ImportError:
        for inbox in INBOXES.values():
            inbox.reset(inbox.me, [])
        return
    INBOXES["work"].reset(persona.MIRA["work_email"], persona.letters())
    INBOXES["personal"].reset(persona.MIRA["email"], persona.personal_letters())


# ---------------------------------------------------------------- requests

class Request:
    def __init__(self, handler, method):
        url = urlparse(handler.path)
        self.method = method
        self.path = url.path
        self.query = {k: v[0] for k, v in parse_qs(url.query).items()}
        self.headers = handler.headers
        self.host = (handler.headers.get("Host") or "").lower()
        self.cookies = {k: v.value for k, v in SimpleCookie(handler.headers.get("Cookie") or "").items()}
        length = int(handler.headers.get("Content-Length") or 0)
        self.body = handler.rfile.read(length) if length else b""
        self.form = {}
        self.json = None
        kind = handler.headers.get("Content-Type") or ""
        if "application/json" in kind and self.body:
            try:
                self.json = json.loads(self.body)
                if isinstance(self.json, dict):
                    self.form = {k: str(v) for k, v in self.json.items()}
            except ValueError:
                pass
        elif self.body:
            self.form = {k: v[0] for k, v in parse_qs(self.body.decode("utf-8", "replace")).items()}


class Reply:
    def __init__(self, status=200, headers=None, body=b"", rate=None):
        self.status = status
        self.headers = headers or {}
        self.body = body if isinstance(body, bytes) else str(body).encode()
        self.rate = rate


class Ctx:
    """What a site's routes.py is given besides the request."""

    def __init__(self, site):
        self.site = site
        self.folder = SITES / site

    @property
    def state(self):
        return state()

    def now(self):
        return time.time()

    def mail(self, sender, subject, text, html=None, thread=None, labels=("INBOX", "UNREAD"), inbox="work"):
        """A letter arrives in Mira's inbox now (work, or personal), as if `sender` had just sent it."""
        return INBOXES[inbox].add(thread=thread or "t%d" % int(time.time() * 1000), sender=sender, subject=subject,
                         body=text, labels=list(labels), html=html)

    def json(self, obj, status=200, headers=None):
        return Reply(status, {"Content-Type": "application/json", **(headers or {})}, json.dumps(obj))

    def html(self, text, status=200, headers=None):
        return Reply(status, {"Content-Type": "text/html; charset=utf-8", **(headers or {})}, text)

    def redirect(self, to, cookies=None):
        headers = {"Location": to}
        if cookies:
            headers["Set-Cookie"] = cookies
        return Reply(303, headers)

    def file(self, path, download=None, rate=None, kind=None):
        """A file of this site's folder, `download` naming it as an attachment;
        `rate` (bytes a second) sends it slowly, for a ring that fills."""
        path = Path(path)
        if not path.is_absolute():
            path = self.folder / path
        data = path.read_bytes()
        headers = {"Content-Type": kind or mimetypes.guess_type(str(path))[0] or "application/octet-stream"}
        if download:
            headers["Content-Disposition"] = 'attachment; filename="%s"' % download
        return Reply(200, headers, data, rate=rate)


def load_sites():
    """Every folder under sites/ with a site.json: {"name", "hosts": [...]},
    and "dev": true for the one site the dev port serves whatever its host."""
    hosts, routes, dev = {}, {}, None
    for folder in sorted(SITES.iterdir()) if SITES.exists() else []:
        meta = folder / "site.json"
        if not meta.exists():
            continue
        info = json.loads(meta.read_text())
        if info.get("dev"):
            dev = folder.name
        for host in info.get("hosts", []):
            hosts[host.lower().split(":")[0]] = folder.name
        script = folder / "routes.py"
        if script.exists():
            spec = importlib.util.spec_from_file_location("site_" + folder.name.replace("-", "_"), script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            routes[folder.name] = module
    return hosts, routes, dev


HOSTS, ROUTES, DEV = load_sites()


def site_for(host, port):
    """The dev port serves the dev site; the sites port tells them apart by
    the host's name (the port in the Host header doesn't matter)."""
    if port == PORTS["dev"]:
        return DEV
    return HOSTS.get(host.lower().split(":")[0])


def static(site, path):
    """The file a path names in a site's folder: index.html for a folder,
    name.html for a bare name. None outside the folder or for nothing."""
    root = (SITES / site).resolve()
    want = (root / path.lstrip("/")).resolve()
    if root not in want.parents and want != root:
        return None
    for candidate in (want, want / "index.html", Path(str(want) + ".html")):
        if candidate.is_file():
            return candidate
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("YAB_DEMO_LOG"):
            sys.stderr.write("%s %s\n" % (self.headers.get("Host"), fmt % args))

    def send(self, reply):
        self.send_response(reply.status)
        headers = {"Cache-Control": "no-store", **reply.headers}
        cookies = headers.pop("Set-Cookie", None)
        for key, value in headers.items():
            self.send_header(key, value)
        for cookie in ([cookies] if isinstance(cookies, str) else cookies or []):
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", str(len(reply.body)))
        self.end_headers()
        if self.command == "HEAD":
            return
        if reply.rate:
            step = max(1024, int(reply.rate / 20))
            for start in range(0, len(reply.body), step):
                self.wfile.write(reply.body[start:start + step])
                self.wfile.flush()
                time.sleep(step / reply.rate)
        else:
            self.wfile.write(reply.body)

    def any(self, method):
        try:
            port = self.server.server_address[1]
            req = Request(self, method)
            if port == PORTS["mail"]:
                return self.mail(req)
            site = site_for(req.host, port)
            if not site:
                return self.send(Reply(404, {"Content-Type": "text/plain"}, "No site answers to %s here." % req.host))
            if req.path == "/__demo/state.json":
                return self.send(Ctx(site).json(state()))
            module = ROUTES.get(site)
            if module and hasattr(module, "handle"):
                reply = module.handle(req, Ctx(site))
                if reply is not None:
                    return self.send(reply)
            found = static(site, req.path)
            if found is None:
                missing = static(site, "/404.html")
                body = missing.read_bytes() if missing else b"Not found"
                return self.send(Reply(404, {"Content-Type": "text/html; charset=utf-8"}, body))
            kind = mimetypes.guess_type(str(found))[0] or "application/octet-stream"
            if kind.startswith("text/") or kind in ("application/javascript", "application/json", "image/svg+xml"):
                kind += "; charset=utf-8"
            self.send(Reply(200, {"Content-Type": kind}, found.read_bytes()))
        except BrokenPipeError:
            pass
        except Exception:
            traceback.print_exc()
            try:
                self.send(Reply(500, {"Content-Type": "text/plain"}, "Server error"))
            except Exception:
                pass

    def mail(self, req):
        if req.path == "/__demo/reset":
            fill_inbox()
            return self.send(Ctx("").json({"ok": True, "messages": {k: len(v.messages) for k, v in INBOXES.items()}}))
        # /work/… and /personal/… are the two mailboxes; a bare path is work.
        name, path = "work", req.path
        for key in INBOXES:
            if path.startswith("/" + key + "/"):
                name, path = key, path[len(key) + 1:]
        inbox = INBOXES[name]
        if path == "/fake/state":
            return self.send(Ctx("").json(inbox.state()))
        if path == "/fake/add":
            return self.send(Ctx("").json({"id": inbox.add(**(req.json or {}))}))
        prefix = "/gmail/v1/users/me/"
        if not path.startswith(prefix):
            return self.send(Ctx("").json({"error": "no"}, 404))
        query = {k: [v] for k, v in req.query.items()}
        status, obj = inbox.answer(req.method, path[len(prefix):], query, req.json or {})
        self.send(Ctx("").json(obj, status))

    def do_GET(self):
        self.any("GET")

    def do_HEAD(self):
        self.any("HEAD")

    def do_POST(self):
        self.any("POST")

    def do_PUT(self):
        self.any("PUT")

    def do_DELETE(self):
        self.any("DELETE")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="say what answers where, then quit")
    parser.add_argument("--sites-port", type=int, default=PORTS["sites"])
    parser.add_argument("--dev-port", type=int, default=PORTS["dev"])
    parser.add_argument("--mail-port", type=int, default=PORTS["mail"])
    args = parser.parse_args()
    PORTS.update(sites=args.sites_port, dev=args.dev_port, mail=args.mail_port)
    fill_inbox()
    if args.check:
        for host, site in sorted(HOSTS.items()):
            print("%-28s %s" % (host, site))
        for inbox in INBOXES.values():
            print("mail: %d letters for %s" % (len(inbox.messages), inbox.me))
        return
    servers = []
    for name, port in PORTS.items():
        server = Server(("127.0.0.1", port), Handler)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print("demo sites on :%d, Tern's dev site on :%d, mail on :%d" % (PORTS["sites"], PORTS["dev"], PORTS["mail"]), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
