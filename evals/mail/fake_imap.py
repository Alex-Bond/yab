#!/usr/bin/env python3
"""A mailbox on IMAP and SMTP, kept in memory, for test worlds
(docs/mail-providers.md, M3): what yab's IMAP account speaks, served plain
on local ports, the folders and flags changed through an HTTP door, so the
mail evals run against IMAP as they do against fake_gmail.py.

    fake = FakeIMAP(); fake.seed(); ports = fake.start()     # threads; ports = {"imap", "smtp", "http"}
    fake.add("INBOX", sender="Ann <ann@example.org>", subject="Hi", body="...")

    python3 evals/mail/fake_imap.py [--imap-port N] [--smtp-port N] [--http-port N]
                                    [--no-condstore] [--no-move] [--no-idle] [--no-special-use] [--no-uidplus]
                                    [--saves-sent] [--selftest] [--provider icloud|zoho|gmail] [--user ADDRESS]

FakeIMAP(user, provider="icloud" or "zoho") is shaped as that provider's
servers are said to be (folders, sign-in names, Sent copies; the class's
own words below), for evals/mail/providers.py.

IMAP4rev1 with LITERAL+, ID, ENABLE, SPECIAL-USE (RFC 6154), CONDSTORE (RFC
7162), MOVE (RFC 6851), UIDPLUS (RFC 4315) and IDLE (RFC 2177), each one
able to be turned off, so the client is held to servers that lack them.
The account: me@example.com, password "app-password" (FakeIMAP(user,
password)); a wrong one is refused as iCloud refuses it, or, with
app_password_hint, saying an app password is wanted.

SMTP submission: EHLO, AUTH PLAIN and LOGIN, MAIL, RCPT, DATA, QUIT; what
it took is in /fake/state "sent", each {from, to, data}; with saves_sent
it also puts a copy in Sent, as iCloud does.

/fake/state (GET): every folder's messages {uid, flags, subject,
message_id}, what SMTP took, the commands each verb was sent, the logins.
/fake/add (POST {folder, sender, subject, body, flags, message_id,
in_reply_to, references, to, ago}), /fake/flags (POST {folder, uid, add,
remove}), /fake/expunge (POST {folder, uid}), /fake/validity (POST {folder}:
a new UIDVALIDITY, every UID renumbered), /fake/options (POST {condstore,
move, idle, ...}).
"""
import hashlib
import argparse, base64, email.utils, json, os, re, socket, socketserver, sys, threading, time, http.server
from datetime import datetime, timedelta, timezone

ME = "me@example.com"
PASSWORD = "app-password"


def now_utc():
    return datetime.now(timezone.utc)


def imap_date(when):
    return when.strftime("%d-%b-%Y %H:%M:%S %z")


def quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Message:
    def __init__(self, uid, raw, flags, when, modseq):
        self.uid = uid
        self.raw = raw
        self.flags = set(flags)
        self.when = when
        self.modseq = modseq

    def header(self, name):
        head = self.raw.split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace")
        value = None
        for line in head.replace("\r\n ", " ").replace("\r\n\t", " ").split("\r\n"):
            if ":" in line and line.split(":", 1)[0].strip().lower() == name.lower():
                value = line.split(":", 1)[1].strip()
                break
        return value or ""

    def head(self):
        return self.raw.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"


class Folder:
    def __init__(self, name, special=None):
        self.name = name
        self.special = special
        self.validity = int(time.time()) % 100000 + len(name)
        self.next_uid = 1
        self.messages = []
        self.modseq = 1

    def find(self, uid):
        for m in self.messages:
            if m.uid == uid:
                return m
        return None


def make_raw(sender, to, subject, body, message_id, when, in_reply_to="", references="", html=None, files=None):
    lines = [
        f"From: {sender}",
        f"To: {to}",
        f"Subject: {subject}",
        f"Date: {email.utils.format_datetime(when)}",
        f"Message-ID: {message_id}",
        "MIME-Version: 1.0",
    ]
    if in_reply_to:
        lines.append(f"In-Reply-To: {in_reply_to}")
    if references:
        lines.append(f"References: {references}")
    if not files and html is None:
        lines += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit", "", body]
        return ("\r\n".join(lines) + "\r\n").encode()
    boundary = "=_yab_fake_" + str(abs(hash(message_id)))
    lines += [f'Content-Type: multipart/mixed; boundary="{boundary}"', "", f"--{boundary}",
              "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable", "",
              body.replace("=", "=3D")]
    if html is not None:
        lines += [f"--{boundary}", "Content-Type: text/html; charset=utf-8", "", html]
    for f in files or []:
        data = base64.b64encode(f["data"]).decode()
        lines += [f"--{boundary}", f'Content-Type: {f.get("mime", "application/octet-stream")}; name="{f["name"]}"',
                  f'Content-Disposition: attachment; filename="{f["name"]}"', "Content-Transfer-Encoding: base64", ""]
        lines += [data[i:i + 76] for i in range(0, len(data), 76)]
    lines += [f"--{boundary}--", ""]
    return "\r\n".join(lines).encode()


class FakeIMAP:
    """`provider` shapes it as a real one is (docs/mail-providers.md, M3):
    "icloud" keeps iCloud's folder names with SPECIAL-USE and a Notes
    folder, takes the name before @ or the whole address at IMAP and the
    whole address at SMTP, and keeps what SMTP sends in Sent Messages
    itself; "zoho" has Zoho's folders (Sent, Spam, Trash, Templates,
    Snoozed, Outbox) and no Archive, no SPECIAL-USE, CONDSTORE or MOVE,
    takes the whole address alone, and refuses SMTP from another address.
    Neither is the real server: what each really does is to be checked on a
    real account by the person."""

    def __init__(self, user=ME, password=PASSWORD, provider=None):
        self.user = user
        self.password = password
        self.provider = provider
        self.lock = threading.RLock()
        self.options = {"condstore": True, "move": True, "idle": True, "special_use": True, "uidplus": True, "literal_plus": True,
                        "saves_sent": False, "app_password_hint": False,
                        # #441's suspects, as a real server might act them: PLAIN (IMAP's
                        # AUTHENTICATE, SMTP's AUTH) closing the line with nothing said where
                        # LOGIN takes the same password; IMAP closing the line on the name
                        # before @ (the whole address only); a refusal said as a BYE.
                        "plain_drops": False, "name_drops": False, "bye_refusals": False}
        self.folders = {}
        self.gmail_threads = {}
        self.options["gmail_extensions"] = provider == "gmail"
        self.options["smtp_hold_ack"] = False
        if provider == "gmail":
            names = [("INBOX", None), ("[Gmail]/All Mail", "\\All"), ("[Gmail]/Sent Mail", "\\Sent"),
                     ("[Gmail]/Drafts", "\\Drafts"), ("[Gmail]/Spam", "\\Junk"), ("[Gmail]/Trash", "\\Trash"),
                     ("[Gmail]/Starred", "\\Flagged"), ("[Gmail]/Important", "\\Important"), ("Projects", None)]
            self.options.update(condstore=False, saves_sent=True)
            self.sent_folder = "[Gmail]/Sent Mail"
        elif provider == "zoho":
            names = [("INBOX", None), ("Drafts", "\\Drafts"), ("Templates", None), ("Snoozed", None), ("Sent", "\\Sent"),
                     ("Spam", "\\Junk"), ("Trash", "\\Trash"), ("Outbox", None), ("Clients", None), ("Clients/Northwind", None)]
            self.options.update(condstore=False, move=False, special_use=False)
            self.sent_folder = "Sent"
        else:
            names = [("INBOX", None), ("Sent Messages", "\\Sent"), ("Archive", "\\Archive"), ("Deleted Messages", "\\Trash"),
                     ("Junk", "\\Junk"), ("Drafts", "\\Drafts"), ("Receipts", None), ("Projects/Yab", None)]
            if provider == "icloud":
                names.append(("Notes", None))
                self.options["saves_sent"] = True
            self.sent_folder = "Sent Messages"
        for name, special in names:
            self.folders[name] = Folder(name, special)
        self.sent = []
        self.calls = {}
        self.logins = []
        self.idlers = []
        self.counter = 0

    def takes(self, user, smtp=False):
        """Whether a sign-in's user name is this account's."""
        if user == self.user:
            return True
        # iCloud's IMAP takes the name before @ too (Apple's help); Zoho and SMTP the whole address.
        return not smtp and self.provider not in ("zoho", "gmail") and user == self.user.split("@")[0]

    # --- the mailbox

    def add(self, folder="INBOX", sender="Ann Lee <ann@example.org>", subject="Hello", body="Hi there.", flags=(), message_id=None,
            in_reply_to="", references="", to=None, ago=0, html=None, files=None, raw=None):
        to = to or self.user
        with self.lock:
            self.counter += 1
            when = now_utc() - timedelta(seconds=ago)
            message_id = message_id or f"<fake-{self.counter}-{int(time.time() * 1000)}@example.org>"
            raw = raw or make_raw(sender, to, subject, body, message_id, when, in_reply_to, references, html, files)
            return self.put(folder, raw, flags, when)

    def put(self, folder, raw, flags=(), when=None):
        with self.lock:
            f = self.folders[folder]
            if self.provider == "gmail":
                rfc = Message(0, raw, (), when or now_utc(), 0).header("message-id")
                old = next((m for m in f.messages if m.header("message-id") == rfc), None)
                if old:
                    return old.uid
                if folder not in ("[Gmail]/All Mail", "[Gmail]/Trash", "[Gmail]/Spam", "[Gmail]/Drafts"):
                    self.put("[Gmail]/All Mail", raw, flags, when)
            f.modseq += 1
            m = Message(f.next_uid, raw, flags, when or now_utc(), f.modseq)
            f.next_uid += 1
            f.messages.append(m)
            self.tell(folder, f"* {len(f.messages)} EXISTS")
            return m.uid

    def tell(self, folder, line):
        for idler in list(self.idlers):
            if idler.selected == folder:
                try:
                    idler.send(line)
                except OSError:
                    pass

    def seed(self):
        """A small mailbox: a thread of two in the inbox, a mail with a file,
        one read and starred, one in Archive, one in Receipts, one of yours in
        Sent; iCloud's has a note in Notes. A Zoho one has mail of its own
        (seed_zoho)."""
        if self.provider == "gmail":
            return self.seed_gmail()
        if self.provider == "zoho":
            return self.seed_zoho()
        a = self.add("INBOX", sender="Mila Novak <mila@studio.example>", subject="Offsite dates", body="Can we do the 14th? Let me know by Friday.",
                     message_id="<offsite-1@studio.example>", ago=3600 * 30)
        self.add("Sent Messages", sender=f"Me <{self.user}>", to="Mila Novak <mila@studio.example>", subject="Re: Offsite dates",
                 body="The 14th works.", message_id="<offsite-2@example.com>", in_reply_to="<offsite-1@studio.example>",
                 references="<offsite-1@studio.example>", flags=["\\Seen"], ago=3600 * 20)
        self.add("INBOX", sender="Mila Novak <mila@studio.example>", subject="Re: Offsite dates", body="Great, booking it now.",
                 message_id="<offsite-3@studio.example>", in_reply_to="<offsite-2@example.com>",
                 references="<offsite-1@studio.example> <offsite-2@example.com>", ago=3600 * 10)
        self.add("INBOX", sender="Tim Okafor <tim@okafor.co>", subject="Contract draft", body="The contract is attached.",
                 message_id="<contract@okafor.co>", files=[{"name": "contract.pdf", "mime": "application/pdf", "data": b"%PDF-1.4 fake"}], ago=7200)
        self.add("INBOX", sender="Linear <no-reply@linear.app>", subject="Weekly digest", body="3 issues closed this week.",
                 message_id="<digest@linear.app>", flags=["\\Seen", "\\Flagged"], ago=5400)
        self.add("INBOX", sender="Ravi Shah <ravi@example.net>", subject="Lunch Thursday?", body="Are you free for lunch Thursday?",
                 message_id="<lunch@example.net>", ago=1800)
        self.add("Archive", sender="Bank <alerts@bank.example>", subject="Statement ready", body="Your statement is ready.",
                 message_id="<statement@bank.example>", flags=["\\Seen"], ago=86400 * 3)
        self.add("Receipts", sender="Shop <orders@shop.example>", subject="Your order", body="Order 1234 shipped.",
                 message_id="<order@shop.example>", flags=["\\Seen"], ago=86400 * 2)
        if self.provider == "icloud":
            self.add("Notes", sender=f"Me <{self.user}>", subject="Grocery list", body="Eggs, rice.", message_id="<note@icloud.example>",
                     flags=["\\Seen"], ago=86400 * 40)
        return a

    def seed_gmail(self):
        self.add("INBOX", subject="Gmail project", message_id="<gmail-one@example.org>", body="First message.")
        # No RFC References: Gmail's thread identity must join these.
        self.add("[Gmail]/Sent Mail", subject="Re: Gmail project", message_id="<gmail-two@example.org>", flags=["\\Seen"])
        self.gmail_threads.update({"<gmail-one@example.org>": 1278455344230334865,
                                   "<gmail-two@example.org>": 1278455344230334865})
        raw = self.folders["INBOX"].messages[0].raw
        self.put("Projects", raw)
        self.add("[Gmail]/All Mail", subject="Archived in Gmail", message_id="<gmail-archive@example.org>", flags=["\\Seen"])
        self.add("[Gmail]/Spam", subject="Gmail spam", message_id="<gmail-spam@example.org>")
        self.add("[Gmail]/Trash", subject="Gmail trash", message_id="<gmail-trash@example.org>")
        self.add("[Gmail]/Drafts", subject="Unsent Gmail draft", message_id="<gmail-draft@example.org>", flags=["\\Draft"])
        self.put("[Gmail]/All Mail", self.folders["[Gmail]/Drafts"].messages[0].raw, ["\\Draft"])

    def gmail_id(self, m):
        return int.from_bytes(hashlib.sha256(m.header("message-id").encode()).digest()[:8], "big")

    def gmail_labels(self, m):
        roles = {"INBOX": "\\Inbox", "[Gmail]/Sent Mail": "\\Sent", "[Gmail]/Trash": "\\Trash",
                 "[Gmail]/Spam": "\\Spam", "[Gmail]/Drafts": "\\Drafts", "[Gmail]/Important": "\\Important"}
        labels = []
        for name, folder in self.folders.items():
            if name in ("[Gmail]/All Mail", "[Gmail]/Starred"):
                continue
            if any(x.header("message-id") == m.header("message-id") for x in folder.messages):
                labels.append(roles.get(name, name))
        return labels

    def gmail_store(self, message, labels, add):
        roles = {"\\Inbox": "INBOX", "\\Sent": "[Gmail]/Sent Mail", "\\Trash": "[Gmail]/Trash",
                 "\\Spam": "[Gmail]/Spam", "\\Important": "[Gmail]/Important"}
        for label in labels:
            name = roles.get(label, label)
            if name not in self.folders:
                self.folders[name] = Folder(name)
            f = self.folders[name]
            if add:
                self.put(name, message.raw, message.flags, message.when)
            else:
                f.messages[:] = [m for m in f.messages if m.header("message-id") != message.header("message-id")]
                f.modseq += 1
        # Gmail changes its labels across every folder view of the message.
        for f in self.folders.values():
            for m in f.messages:
                if m.header("message-id") == message.header("message-id"):
                    f.modseq += 1
                    m.modseq = f.modseq

    def seed_zoho(self):
        """A Zoho mailbox: a thread with your reply in Sent, an invoice with
        its file, a reminder read, a client's mail in a folder of its own,
        a template and a snoozed mail where Zoho keeps them."""
        me = self.user
        a = self.add("INBOX", sender="Dana Cole <dana@harbor.example>", subject="Kickoff agenda",
                     body="Here is the agenda for Monday. Anything to add?", message_id="<kickoff-1@harbor.example>", ago=3600 * 26)
        self.add("Sent", sender=f"Sam Rivers <{me}>", to="Dana Cole <dana@harbor.example>", subject="Re: Kickoff agenda",
                 body="Add the budget review, please.", message_id="<kickoff-2@zohomail.example>", in_reply_to="<kickoff-1@harbor.example>",
                 references="<kickoff-1@harbor.example>", flags=["\\Seen"], ago=3600 * 22)
        self.add("INBOX", sender="Dana Cole <dana@harbor.example>", subject="Re: Kickoff agenda", body="Added. See you Monday.",
                 message_id="<kickoff-3@harbor.example>", in_reply_to="<kickoff-2@zohomail.example>",
                 references="<kickoff-1@harbor.example> <kickoff-2@zohomail.example>", ago=3600 * 3)
        self.add("INBOX", sender="Priya Raman <priya@northwind.example>", subject="Invoice 0147 for October",
                 body="The October invoice is attached.", message_id="<invoice-0147@northwind.example>",
                 files=[{"name": "invoice-0147.pdf", "mime": "application/pdf", "data": b"%PDF-1.4 invoice"}], ago=5400)
        self.add("INBOX", sender="Harbor Calendar <calendar@harbor.example>", subject="Reminder: design review at 3pm",
                 body="Design review today at 3pm in Room 2.", message_id="<review@harbor.example>", flags=["\\Seen"], ago=4000)
        self.add("INBOX", sender="Owen Park <owen@example.net>", subject="Photos from Saturday", body="Sending the photos tonight.",
                 message_id="<photos@example.net>", ago=1200)
        self.add("Clients", sender="Priya Raman <priya@northwind.example>", subject="Northwind renewal", body="Renewal terms for next year.",
                 message_id="<renewal@northwind.example>", flags=["\\Seen"], ago=86400 * 4)
        self.add("Templates", sender=f"Sam Rivers <{me}>", subject="Weekly update template", body="This week:",
                 message_id="<template@zohomail.example>", flags=["\\Seen"], ago=86400 * 30)
        self.add("Snoozed", sender="Owen Park <owen@example.net>", subject="Book club pick", body="Your turn to pick.",
                 message_id="<bookclub@example.net>", ago=86400)
        return a

    def state(self):
        with self.lock:
            return {
                "folders": {name: [{"uid": m.uid, "flags": sorted(m.flags), "subject": m.header("subject"), "message_id": m.header("message-id"),
                                    "from": m.header("from"), "to": m.header("to")} for m in f.messages] for name, f in self.folders.items()},
                "sent": [{"from": s["from"], "to": s["to"], "data": s["data"]} for s in self.sent],
                "calls": dict(self.calls), "logins": list(self.logins), "options": dict(self.options),
            }

    def count(self, verb):
        with self.lock:
            self.calls[verb] = self.calls.get(verb, 0) + 1

    def capabilities(self, authed):
        caps = ["IMAP4rev1", "ID", "ENABLE", "UNSELECT", "AUTH=PLAIN", "SASL-IR"]
        if self.options["gmail_extensions"]:
            caps.append("X-GM-EXT-1")
        if self.options["literal_plus"]:
            caps.append("LITERAL+")
        if self.options["special_use"]:
            caps.append("SPECIAL-USE")
        if self.options["condstore"]:
            caps.append("CONDSTORE")
        if self.options["move"]:
            caps.append("MOVE")
        if self.options["uidplus"]:
            caps.append("UIDPLUS")
        if self.options["idle"]:
            caps.append("IDLE")
        return " ".join(caps)

    # --- the servers

    def start(self, imap_port=0, smtp_port=0, http_port=0):
        fake = self

        class IMAPHandler(socketserver.StreamRequestHandler):
            def handle(self):
                IMAPSession(fake, self.rfile, self.wfile).run()

        class SMTPHandler(socketserver.StreamRequestHandler):
            def handle(self):
                SMTPSession(fake, self.rfile, self.wfile).run()

        class Threaded(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.imap_server = Threaded(("127.0.0.1", imap_port), IMAPHandler)
        self.smtp_server = Threaded(("127.0.0.1", smtp_port), SMTPHandler)
        self.http_server = http.server.ThreadingHTTPServer(("127.0.0.1", http_port), self.http_handler())
        for server in (self.imap_server, self.smtp_server, self.http_server):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        return {"imap": self.imap_server.server_address[1], "smtp": self.smtp_server.server_address[1],
                "http": self.http_server.server_address[1]}

    def http_handler(self):
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, obj, status=200):
                data = json.dumps(obj).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path.startswith("/fake/state"):
                    return self.reply(fake.state())
                self.reply({"error": "no such path"}, 404)

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                with fake.lock:
                    if self.path == "/fake/add":
                        uid = fake.add(body.get("folder", "INBOX"), sender=body.get("sender", "Ann Lee <ann@example.org>"),
                                       subject=body.get("subject", "Hello"), body=body.get("body", "Hi."), flags=body.get("flags", []),
                                       message_id=body.get("message_id"), in_reply_to=body.get("in_reply_to", ""),
                                       references=body.get("references", ""), to=body.get("to"), ago=body.get("ago", 0))
                        return self.reply({"ok": True, "uid": uid})
                    if self.path == "/fake/flags":
                        f = fake.folders[body.get("folder", "INBOX")]
                        m = f.find(int(body["uid"]))
                        if not m:
                            return self.reply({"error": "no such uid"}, 404)
                        m.flags |= set(body.get("add", []))
                        m.flags -= set(body.get("remove", []))
                        f.modseq += 1
                        m.modseq = f.modseq
                        fake.tell(f.name, f"* {f.messages.index(m) + 1} FETCH (UID {m.uid} FLAGS ({' '.join(sorted(m.flags))}))")
                        return self.reply({"ok": True})
                    if self.path == "/fake/expunge":
                        f = fake.folders[body.get("folder", "INBOX")]
                        m = f.find(int(body["uid"]))
                        if m:
                            n = f.messages.index(m) + 1
                            f.messages.remove(m)
                            f.modseq += 1
                            fake.tell(f.name, f"* {n} EXPUNGE")
                        return self.reply({"ok": True})
                    if self.path == "/fake/validity":
                        f = fake.folders[body.get("folder", "INBOX")]
                        f.validity += 1000
                        for n, m in enumerate(f.messages, 1):
                            m.uid = n
                        f.next_uid = len(f.messages) + 1
                        return self.reply({"ok": True, "validity": f.validity})
                    if self.path == "/fake/options":
                        fake.options.update({k: v for k, v in body.items() if k in fake.options})
                        return self.reply({"ok": True, "options": fake.options})
                self.reply({"error": "no such path"}, 404)

        return Handler


class Args:
    """A command's arguments, IMAP's way: atoms, quoted strings, literals, lists."""

    def __init__(self, text, literals):
        self.text = text
        self.at = 0
        self.literals = literals

    def space(self):
        while self.at < len(self.text) and self.text[self.at] == " ":
            self.at += 1

    def done(self):
        self.space()
        return self.at >= len(self.text)

    def rest(self):
        self.space()
        out = self.text[self.at:]
        self.at = len(self.text)
        return out

    def next(self):
        self.space()
        if self.at >= len(self.text):
            return None
        c = self.text[self.at]
        if c == '"':
            self.at += 1
            out = ""
            while self.at < len(self.text) and self.text[self.at] != '"':
                if self.text[self.at] == "\\":
                    self.at += 1
                out += self.text[self.at]
                self.at += 1
            self.at += 1
            return out
        if c == "(":
            self.at += 1
            items = []
            while True:
                self.space()
                if self.at >= len(self.text) or self.text[self.at] == ")":
                    self.at += 1
                    return items
                items.append(self.next())
        m = re.match(r"\{(\d+)\+?\}\x00(\d+)\x00", self.text[self.at:])
        if m:
            self.at += m.end()
            return self.literals[int(m.group(2))]
        start = self.at
        depth = 0
        while self.at < len(self.text):
            ch = self.text[self.at]
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
            elif depth == 0 and ch in " ()":
                break
            self.at += 1
        return self.text[start:self.at]


def uid_set(text, top):
    out = set()
    for piece in text.split(","):
        if ":" in piece:
            a, b = piece.split(":")
            a = top if a == "*" else int(a)
            b = top if b == "*" else int(b)
            lo, hi = min(a, b), max(a, b)
            out.update(range(lo, hi + 1))
        elif piece == "*":
            out.add(top)
        elif piece:
            out.add(int(piece))
    return out


class IMAPSession:
    def __init__(self, fake, rfile, wfile):
        self.fake = fake
        self.rfile = rfile
        self.wfile = wfile
        self.authed = False
        self.selected = None
        self.condstore = False
        self.write_lock = threading.Lock()

    def send(self, line):
        data = line if isinstance(line, bytes) else line.encode()
        with self.write_lock:
            self.wfile.write(data + b"\r\n")
            self.wfile.flush()

    def read_command(self):
        """A command line with its literals: each {n} replaced by a mark."""
        literals = []
        text = ""
        while True:
            line = self.rfile.readline()
            if not line:
                return None, None
            line = line.rstrip(b"\r\n")
            m = re.search(rb"\{(\d+)(\+?)\}$", line)
            if not m:
                text += line.decode("utf-8", "replace")
                return text, literals
            n = int(m.group(1))
            if not m.group(2):
                self.send("+ go ahead")
            data = self.rfile.read(n)
            text += line[:m.start()].decode("utf-8", "replace") + "{%d}\x00%d\x00" % (n, len(literals))
            literals.append(data)

    def run(self):
        self.send("* OK [CAPABILITY " + self.fake.capabilities(False) + "] Fake IMAP ready")
        while True:
            try:
                text, literals = self.read_command()
            except (ConnectionError, OSError):
                return
            if text is None:
                return
            parts = text.split(" ", 2)
            if len(parts) < 2:
                self.send("* BAD what")
                continue
            tag, verb = parts[0], parts[1].upper()
            args = Args(parts[2] if len(parts) > 2 else "", literals)
            if verb == "UID":
                sub = args.next().upper()
                verb = "UID " + sub
            self.fake.count(verb)
            try:
                if not self.dispatch(tag, verb, args):
                    return
            except Exception as e:  # noqa: BLE001
                self.send(f"{tag} BAD {type(e).__name__}: {e}")

    def folder(self):
        return self.fake.folders.get(self.selected)

    def dispatch(self, tag, verb, args):
        fake = self.fake
        if verb == "CAPABILITY":
            self.send("* CAPABILITY " + fake.capabilities(self.authed))
            self.send(f"{tag} OK done")
        elif verb == "NOOP":
            self.send(f"{tag} OK done")
        elif verb == "LOGOUT":
            self.send("* BYE see you")
            self.send(f"{tag} OK done")
            return False
        elif verb == "ID":
            self.send('* ID ("name" "fake")')
            self.send(f"{tag} OK done")
        elif verb == "ENABLE":
            wanted = args.rest().upper().split()
            on = [w for w in wanted if w == "CONDSTORE" and fake.options["condstore"]]
            if on:
                self.condstore = True
            self.send("* ENABLED " + " ".join(on))
            self.send(f"{tag} OK done")
        elif verb == "LOGIN":
            user, password = args.next(), args.next()
            return self.login(tag, user, password)
        elif verb == "AUTHENTICATE":
            mech = args.next().upper()
            if mech != "PLAIN":
                self.send(f"{tag} NO no such mechanism")
                return True
            initial = args.next()
            if initial is None:
                self.send("+ ")
                initial = self.rfile.readline().strip().decode()
            try:
                _, user, password = base64.b64decode(initial).decode().split("\x00")
            except Exception:  # noqa: BLE001
                self.send(f"{tag} BAD not plain")
                return True
            if fake.options["plain_drops"]:
                fake.logins.append("plain-dropped:" + user)
                return False
            return self.login(tag, user, password)
        elif not self.authed:
            self.send(f"{tag} NO sign in first")
        elif verb == "LIST":
            ref, pattern = args.next(), args.next()
            special = not args.done() and fake.options["special_use"]
            for f in fake.folders.values():
                attrs = ["\\HasNoChildren"]
                if f.special and fake.options["special_use"]:
                    attrs.append(f.special)
                self.send(f'* LIST ({" ".join(attrs)}) "/" {quote(f.name)}')
            self.send(f"{tag} OK done")
        elif verb in ("SELECT", "EXAMINE"):
            name = args.next()
            if not args.done() and "CONDSTORE" in args.rest().upper():
                self.condstore = fake.options["condstore"]
            f = fake.folders.get(name)
            if not f:
                self.send(f"{tag} NO no such folder")
                return True
            self.selected = name
            self.send(f"* {len(f.messages)} EXISTS")
            self.send("* 0 RECENT")
            self.send("* FLAGS (\\Seen \\Flagged \\Deleted \\Answered \\Draft)")
            self.send(f"* OK [UIDVALIDITY {f.validity}] valid")
            self.send(f"* OK [UIDNEXT {f.next_uid}] next")
            if fake.options["condstore"]:
                self.send(f"* OK [HIGHESTMODSEQ {f.modseq}] modseq")
            self.send(f"{tag} OK [{'READ-ONLY' if verb == 'EXAMINE' else 'READ-WRITE'}] done")
        elif verb == "STATUS":
            name = args.next()
            f = fake.folders.get(name)
            if not f:
                self.send(f"{tag} NO no such folder")
                return True
            unseen = sum(1 for m in f.messages if "\\Seen" not in m.flags)
            extra = f" HIGHESTMODSEQ {f.modseq}" if fake.options["condstore"] else ""
            self.send(f"* STATUS {quote(name)} (MESSAGES {len(f.messages)} UNSEEN {unseen} UIDNEXT {f.next_uid} UIDVALIDITY {f.validity}{extra})")
            self.send(f"{tag} OK done")
        elif verb == "CREATE":
            name = args.next()
            if name in fake.folders:
                self.send(f"{tag} NO [ALREADYEXISTS] exists")
            else:
                fake.folders[name] = Folder(name, "\\Archive" if name == "Archive" else None)
                self.send(f"{tag} OK done")
        elif verb == "DELETE":
            name = args.next()
            fake.folders.pop(name, None)
            self.send(f"{tag} OK done")
        elif verb == "RENAME":
            a, b = args.next(), args.next()
            f = fake.folders.pop(a)
            f.name = b
            fake.folders[b] = f
            self.send(f"{tag} OK done")
        elif verb == "APPEND":
            name = args.next()
            flags = []
            nxt = args.next()
            if isinstance(nxt, list):
                flags = nxt
                nxt = args.next()
            data = nxt if isinstance(nxt, bytes) else args.next()
            f = fake.folders.get(name)
            if not f:
                self.send(f"{tag} NO [TRYCREATE] no such folder")
                return True
            uid = fake.put(name, data, flags)
            code = f"[APPENDUID {f.validity} {uid}] " if fake.options["uidplus"] else ""
            self.send(f"{tag} OK {code}done")
        elif verb == "IDLE":
            if not fake.options["idle"]:
                self.send(f"{tag} BAD no idle")
                return True
            self.send("+ idling")
            fake.idlers.append(self)
            try:
                while True:
                    line = self.rfile.readline()
                    if not line or line.strip().upper() == b"DONE":
                        break
            finally:
                fake.idlers.remove(self)
            self.send(f"{tag} OK idle done")
        elif verb in ("EXPUNGE", "UID EXPUNGE"):
            f = self.folder()
            wanted = uid_set(args.next(), f.next_uid) if verb == "UID EXPUNGE" else None
            for m in list(f.messages):
                if "\\Deleted" in m.flags and (wanted is None or m.uid in wanted):
                    n = f.messages.index(m) + 1
                    f.messages.remove(m)
                    self.send(f"* {n} EXPUNGE")
            f.modseq += 1
            self.send(f"{tag} OK done")
        elif verb == "UID SEARCH":
            self.search(tag, args)
        elif verb == "UID FETCH":
            self.fetch(tag, args)
        elif verb == "UID STORE":
            self.store(tag, args)
        elif verb in ("UID MOVE", "UID COPY"):
            if verb == "UID MOVE" and not fake.options["move"]:
                self.send(f"{tag} BAD no move")
                return True
            self.copy(tag, args, move=verb == "UID MOVE")
        else:
            self.send(f"{tag} BAD unknown {verb}")
        return True

    def login(self, tag, user, password):
        """A sign-in answered; False when the line is to close."""
        fake = self.fake
        fake.logins.append(user)
        if fake.options["name_drops"] and "@" not in user and user != fake.user:
            return False
        if not fake.takes(user) or password != fake.password:
            if fake.options["bye_refusals"]:
                self.send("* BYE [ALERT] Too many failed sign-ins. Try again later.")
                return False
            if fake.options["app_password_hint"]:
                self.send(f"{tag} NO [AUTHENTICATIONFAILED] Application-specific password required")
            else:
                self.send(f"{tag} NO [AUTHENTICATIONFAILED] Authentication failed.")
            return True
        self.authed = True
        self.send(f"{tag} OK [CAPABILITY {fake.capabilities(True)}] signed in")
        return True

    def search(self, tag, args):
        """UID SEARCH's keys (RFC 3501, 6.4.4) as yab sends them, nested in
        lists, NOT and OR, CHARSET UTF-8 with literals."""
        f = self.folder()
        words = []
        while not args.done():
            words.append(args.next())
        if words and isinstance(words[0], str) and words[0].upper() == "CHARSET":
            words = words[2:]
        top = max((m.uid for m in f.messages), default=0)

        def text(v):
            return (v.decode("utf-8", "replace") if isinstance(v, bytes) else v).lower()

        def body(m):
            return m.raw.decode("utf-8", "replace").lower()

        def key(ws, at):
            """One search key from ws[at]: a test on a message, and where the next begins."""
            w = ws[at]
            if isinstance(w, list):
                tests = []
                i = 0
                while i < len(w):
                    t, i = key(w, i)
                    tests.append(t)
                return (lambda m: all(t(m) for t in tests)), at + 1
            u = w.upper()
            if u == "ALL":
                return (lambda m: True), at + 1
            if u in ("UNSEEN", "SEEN", "FLAGGED", "UNFLAGGED"):
                flag = "\\Flagged" if "FLAGGED" in u else "\\Seen"
                on = not u.startswith("UN")
                return (lambda m: (flag in m.flags) == on), at + 1
            if u in ("SINCE", "BEFORE"):
                day = datetime.strptime(ws[at + 1], "%d-%b-%Y").replace(tzinfo=timezone.utc)
                if u == "SINCE":
                    return (lambda m: m.when >= day), at + 2
                return (lambda m: m.when < day), at + 2
            if u == "UID":
                wanted = uid_set(ws[at + 1], top)
                return (lambda m: m.uid in wanted), at + 2
            if u == "HEADER":
                name, value = ws[at + 1], text(ws[at + 2])
                return (lambda m: value in m.header(name).lower()), at + 3
            if u in ("FROM", "TO", "CC", "BCC", "SUBJECT"):
                value = text(ws[at + 1])
                return (lambda m: value in m.header(u.lower()).lower()), at + 2
            if u in ("TEXT", "BODY"):
                value = text(ws[at + 1])
                return (lambda m: value in body(m)), at + 2
            if u == "NOT":
                t, nxt = key(ws, at + 1)
                return (lambda m: not t(m)), nxt
            if u == "OR":
                a_, i = key(ws, at + 1)
                b_, nxt = key(ws, i)
                return (lambda m: a_(m) or b_(m)), nxt
            raise ValueError("unknown search key " + w)

        tests = []
        at = 0
        while at < len(words):
            t, at = key(words, at)
            tests.append(t)
        found = [m for m in f.messages if all(t(m) for t in tests)]
        self.send("* SEARCH" + "".join(f" {m.uid}" for m in found))
        self.send(f"{tag} OK done")

    def fetch(self, tag, args):
        f = self.folder()
        top = max((m.uid for m in f.messages), default=0)
        wanted = uid_set(args.next(), top)
        items = args.next()
        if isinstance(items, str):
            items = [items]
        since = None
        if not args.done():
            mod = args.next()
            if isinstance(mod, list) and len(mod) == 2 and str(mod[0]).upper() == "CHANGEDSINCE":
                since = int(mod[1])
        for n, m in enumerate(f.messages, 1):
            if m.uid not in wanted or (since is not None and m.modseq <= since):
                continue
            out = [b"UID %d" % m.uid]
            for item in items:
                name = item.upper()
                if name == "X-GM-MSGID" and self.fake.options["gmail_extensions"]:
                    out.append(f"X-GM-MSGID {self.fake.gmail_id(m)}".encode())
                elif name == "X-GM-THRID" and self.fake.options["gmail_extensions"]:
                    out.append(f"X-GM-THRID {self.fake.gmail_threads.get(m.header('message-id'), self.fake.gmail_id(m))}".encode())
                elif name == "X-GM-LABELS" and self.fake.options["gmail_extensions"]:
                    out.append(("X-GM-LABELS (" + " ".join(quote(x) for x in self.fake.gmail_labels(m)) + ")").encode())
                elif name == "FLAGS":
                    out.append(("FLAGS (" + " ".join(sorted(m.flags)) + ")").encode())
                elif name == "INTERNALDATE":
                    out.append(b'INTERNALDATE "' + imap_date(m.when).encode() + b'"')
                elif name == "RFC822.SIZE":
                    out.append(b"RFC822.SIZE %d" % len(m.raw))
                elif name in ("BODY.PEEK[]", "BODY[]"):
                    out.append(b"BODY[] {%d}\r\n" % len(m.raw) + m.raw)
                    if name == "BODY[]":
                        m.flags.add("\\Seen")
                elif name in ("BODY.PEEK[HEADER]", "BODY[HEADER]"):
                    head = m.head()
                    out.append(b"BODY[HEADER] {%d}\r\n" % len(head) + head)
            if self.condstore or since is not None:
                out.append(b"MODSEQ (%d)" % m.modseq)
            self.send(b"* %d FETCH (" % n + b" ".join(out) + b")")
        self.send(f"{tag} OK done")

    def store(self, tag, args):
        f = self.folder()
        top = max((m.uid for m in f.messages), default=0)
        wanted = uid_set(args.next(), top)
        how = args.next().upper()
        flags = args.next()
        if isinstance(flags, str):
            flags = [flags]
        if "X-GM-LABELS" in how:
            if not self.fake.options["gmail_extensions"]:
                self.send(f"{tag} BAD unsupported Gmail extension")
                return
            self.fake.count("gmail_labels")
            for m in list(f.messages):
                if m.uid in wanted:
                    self.fake.gmail_store(m, flags, how.startswith("+"))
            self.send(f"{tag} OK labels changed")
            return
        for n, m in enumerate(f.messages, 1):
            if m.uid not in wanted:
                continue
            if how.startswith("+"):
                m.flags |= set(flags)
            elif how.startswith("-"):
                m.flags -= set(flags)
            else:
                m.flags = set(flags)
            f.modseq += 1
            m.modseq = f.modseq
            if not how.endswith(".SILENT"):
                self.send(f"* {n} FETCH (UID {m.uid} FLAGS ({' '.join(sorted(m.flags))}))")
        self.send(f"{tag} OK done")

    def copy(self, tag, args, move):
        fake = self.fake
        f = self.folder()
        top = max((m.uid for m in f.messages), default=0)
        wanted = uid_set(args.next(), top)
        target = fake.folders.get(args.next())
        if not target:
            self.send(f"{tag} NO [TRYCREATE] no such folder")
            return
        old, new = [], []
        for m in list(f.messages):
            if m.uid not in wanted:
                continue
            uid = fake.put(target.name, m.raw, m.flags - {"\\Deleted"}, m.when)
            old.append(m.uid)
            new.append(uid)
            if move:
                n = f.messages.index(m) + 1
                f.messages.remove(m)
                f.modseq += 1
                self.send(f"* {n} EXPUNGE")
        code = ""
        if fake.options["uidplus"] and old:
            code = f"[COPYUID {target.validity} {','.join(map(str, old))} {','.join(map(str, new))}] "
        if move and code:
            self.send(f"* OK {code}moved")
            code = ""
        self.send(f"{tag} OK {code}done")


class SMTPSession:
    def __init__(self, fake, rfile, wfile):
        self.fake = fake
        self.rfile = rfile
        self.wfile = wfile
        self.authed = False
        self.sender = None
        self.to = []

    def send(self, line):
        self.wfile.write(line.encode() + b"\r\n")
        self.wfile.flush()

    def run(self):
        fake = self.fake
        self.send("220 fake.smtp ready")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            text = line.decode("utf-8", "replace").rstrip("\r\n")
            verb = text.split(" ", 1)[0].upper()
            fake.count("SMTP " + verb)
            if verb in ("EHLO", "HELO"):
                self.send("250-fake.smtp")
                self.send("250-SIZE 35882577")
                self.send("250-AUTH PLAIN LOGIN")
                self.send("250 8BITMIME")
            elif verb == "AUTH":
                parts = text.split(" ")
                if parts[1].upper() == "PLAIN":
                    initial = parts[2] if len(parts) > 2 else None
                    if initial is None:
                        self.send("334 ")
                        initial = self.rfile.readline().strip().decode()
                    _, user, password = base64.b64decode(initial).decode().split("\x00")
                    if fake.options["plain_drops"]:
                        fake.logins.append("smtp-plain-dropped:" + user)
                        return
                else:
                    self.send("334 VXNlcm5hbWU6")
                    user = base64.b64decode(self.rfile.readline().strip()).decode()
                    self.send("334 UGFzc3dvcmQ6")
                    password = base64.b64decode(self.rfile.readline().strip()).decode()
                fake.logins.append("smtp:" + user)
                if fake.takes(user, smtp=True) and password == fake.password:
                    self.authed = True
                    self.send("235 2.7.0 accepted")
                else:
                    self.send("535 5.7.8 Authentication credentials invalid")
            elif verb == "MAIL":
                if not self.authed:
                    self.send("530 5.7.0 sign in first")
                    continue
                self.sender = re.search(r"<([^>]*)>", text).group(1)
                self.to = []
                # Zoho sends only from the account's own address.
                if fake.provider == "zoho" and self.sender.lower() != fake.user.lower():
                    self.send("553 5.7.1 Sender is not allowed to relay emails")
                    continue
                self.send("250 ok")
            elif verb == "RCPT":
                self.to.append(re.search(r"<([^>]*)>", text).group(1))
                self.send("250 ok")
            elif verb == "DATA":
                self.send("354 go ahead")
                lines = []
                while True:
                    one = self.rfile.readline()
                    if one in (b".\r\n", b".\n", b""):
                        break
                    if one.startswith(b".."):
                        one = one[1:]
                    lines.append(one)
                data = b"".join(lines)
                with fake.lock:
                    fake.sent.append({"from": self.sender, "to": self.to, "data": data.decode("utf-8", "replace")})
                    if fake.options["saves_sent"]:
                        fake.put(fake.sent_folder, data, ["\\Seen"])
                # Expose Gmail's Sent copy before SMTP acknowledges it.
                # The HTTP controller releases this deterministic race fixture.
                until = time.monotonic() + 20
                while fake.options["smtp_hold_ack"] and time.monotonic() < until:
                    time.sleep(0.01)
                if fake.provider == "gmail":
                    fake.count("SMTP ACK")
                self.send("250 2.0.0 queued")
            elif verb == "RSET":
                self.sender, self.to = None, []
                self.send("250 ok")
            elif verb == "QUIT":
                self.send("221 bye")
                return
            elif verb == "NOOP":
                self.send("250 ok")
            else:
                self.send("502 not here")


def selftest(opts):
    """The fake held to Python's own clients (imaplib, smtplib)."""
    import imaplib, smtplib
    fake = FakeIMAP()
    fake.seed()
    for key in ("condstore", "move", "idle"):
        if getattr(opts, "no_" + key):
            fake.options[key] = False
    ports = fake.start()
    fails = []

    def check(what, ok, detail=""):
        print(("✓ " if ok else "✗ ") + what + ("" if ok else f": {detail}"))
        if not ok:
            fails.append(what)

    m = imaplib.IMAP4("127.0.0.1", ports["imap"])
    check("a wrong password is refused", _refused(m))
    m = imaplib.IMAP4("127.0.0.1", ports["imap"])
    m.login(ME, PASSWORD)
    typ, folders = m.list()
    check("LIST names Sent by SPECIAL-USE", any(b"\\Sent" in f and b"Sent Messages" in f for f in folders), folders)
    typ, data = m.select("INBOX")
    check("the inbox holds the seed", int(data[0]) == 5, data)
    typ, data = m.uid("SEARCH", None, "ALL")
    uids = data[0].split()
    check("UID SEARCH ALL", len(uids) == 5, data)
    typ, data = m.uid("FETCH", uids[0], "(UID FLAGS BODY.PEEK[HEADER])")
    check("a header comes as a literal", b"Offsite dates" in data[0][1], data)
    typ, data = m.uid("STORE", uids[0], "+FLAGS.SILENT", "(\\Seen)")
    typ, data = m.uid("FETCH", uids[0], "(FLAGS)")
    check("STORE sets a flag", b"\\Seen" in data[0], data)
    typ, data = m.uid("MOVE", uids[0], "Archive") if fake.options["move"] else m.uid("COPY", uids[0], "Archive")
    check("MOVE or COPY goes", typ == "OK", (typ, data))
    typ, data = m.append('"Sent Messages"', "(\\Seen)", None, b"From: me@example.com\r\nSubject: appended\r\nMessage-ID: <app@x>\r\n\r\nhi\r\n")
    check("APPEND says its UID", typ == "OK", (typ, data))
    m.logout()
    s = smtplib.SMTP("127.0.0.1", ports["smtp"])
    s.login(ME, PASSWORD)
    s.sendmail(ME, ["ann@example.org"], b"From: me@example.com\r\nTo: ann@example.org\r\nSubject: sent\r\n\r\n.dot line\r\n")
    s.quit()
    check("SMTP takes a message, dots undone", fake.sent and fake.sent[-1]["data"].find("\r\n.dot line") >= 0, fake.sent)
    print("all good" if not fails else f"{len(fails)} failed")
    return 1 if fails else 0


def _refused(m):
    try:
        m.login(ME, "wrong")
        return False
    except Exception:  # noqa: BLE001
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--imap-port", type=int, default=0)
    parser.add_argument("--smtp-port", type=int, default=0)
    parser.add_argument("--http-port", type=int, default=0)
    for key in ("condstore", "move", "idle", "special-use", "uidplus"):
        parser.add_argument("--no-" + key, action="store_true")
    parser.add_argument("--saves-sent", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--empty", action="store_true", help="no seed mail")
    parser.add_argument("--provider", choices=["icloud", "zoho", "gmail"], help="shaped as that provider's servers are")
    parser.add_argument("--user", default=ME)
    opts = parser.parse_args()
    if opts.selftest:
        sys.exit(selftest(opts))
    fake = FakeIMAP(user=opts.user, provider=opts.provider)
    if not opts.empty:
        fake.seed()
    for key in ("condstore", "move", "idle", "special_use", "uidplus"):
        if getattr(opts, "no_" + key):
            fake.options[key] = False
    if opts.saves_sent:
        fake.options["saves_sent"] = True
    ports = fake.start(opts.imap_port, opts.smtp_port, opts.http_port)
    print(json.dumps(ports), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
