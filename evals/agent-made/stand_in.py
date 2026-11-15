#!/usr/bin/env python3
# A stand-in Claude for evals/agent-made/check.py (from agent-basics'): speaks
# Claude Code's stream-json and calls Yab's save_file and copy through the
# real MCP server Yab gives it, logging each tool's answer.
#
#   "files"    saves Team.csv (48 people) and Talks.ics (4 talks), then copies
#              the 14 addresses
#   "link"     copies the fixture page's link with its title, to a paragraph
#   "thefile"  saves Report.json and copies the file itself
#   "outside"  asks to copy /etc/hosts and to save "../../escape.csv"
#   "emails"   copies the 14 addresses only (the answer card)
#   anything else gets a short answer naming what it heard
import json, os, queue, subprocess, sys, threading, time, uuid

args = sys.argv[1:]
if "--mcp-config" not in args:
    print(json.dumps({"loggedIn": True})); sys.exit(0)
LOG = open(os.environ.get("AGENT_MADE_LOG", os.devnull), "a")
PAGE = os.environ.get("AGENT_MADE_PAGE", "about:blank")
resume = args[args.index("--resume") + 1] if "--resume" in args else ""
SID = resume or "made-" + uuid.uuid4().hex[:8]
config = json.loads(args[args.index("--mcp-config") + 1])
server = next(iter(config["mcpServers"].values()))
P = "mcp__yab-browser__"


def out(o): print(json.dumps(o), flush=True)
def log(*a): print(f"{time.time():.3f}", *a, file=LOG, flush=True)
def say(words): out({"type": "assistant", "message": {"id": "msg_" + uuid.uuid4().hex[:12], "content": [{"type": "text", "text": words}]}})


class Mcp:
    def __init__(self):
        self.p = subprocess.Popen([server["command"]] + server.get("args", []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=LOG, text=True)
        self.n = 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "made", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); self.p.stdin.flush()

    def call(self, m, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": m, "params": params or {}}) + "\n"); self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line: return {"result": {"content": [{"text": "(server gone)"}], "isError": True}}
            r = json.loads(line)
            if r.get("id") == self.n: return r

    def tool(self, tool, **a):
        tid = "toolu_" + uuid.uuid4().hex[:20]
        out({"type": "assistant", "message": {"id": "msg_" + uuid.uuid4().hex[:20], "content": [{"type": "tool_use", "id": tid, "name": P + tool, "input": a}]}})
        res = self.call("tools/call", {"name": tool, "arguments": a}).get("result") or {}
        said = "\n".join(c.get("text", "") for c in (res.get("content") or []) if c.get("type") == "text")
        log("TOOL", tool, said.replace("\n", " | ")[:300])
        out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": said[:2000], "is_error": bool(res.get("isError"))}]}})
        return said

    def close(self):
        try: self.p.stdin.close(); self.p.terminate()
        except Exception: pass


heard = queue.Queue()


def read():
    for line in iter(sys.stdin.readline, ""):
        try: msg = json.loads(line)
        except ValueError: continue
        if msg.get("type") != "user": continue
        content = msg["message"]["content"]
        text = content if isinstance(content, str) else "".join(c.get("text", "") for c in content if isinstance(c, dict))
        heard.put((msg, text))
    heard.put((None, None))


EMAILS = "\n".join(f"person{n}@example.com" for n in range(1, 15))
TEAM = "name,email,team\n" + "\n".join(f"Person {n},person{n}@example.com,\"Team {n % 4}, north\"" for n in range(1, 49)) + "\n"
TALKS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Yab eval//EN\r\n" + "".join(
    f"BEGIN:VEVENT\r\nUID:talk{n}@example.com\r\nDTSTART:2026112{n}T180000Z\r\nDTEND:2026112{n}T190000Z\r\nSUMMARY:Lantern talk {n}\r\nEND:VEVENT\r\n"
    for n in range(1, 5)) + "END:VCALENDAR\r\n"
QUOTE = "The Velmora lantern walk starts at 21:40 from the north pier."


def act(m, low):
    if "files:" in low:
        m.tool("name", name="Team sheet and talks")
        a = m.tool("save_file", name="Team.csv", text=TEAM)
        b = m.tool("save_file", name="Talks.ics", text=TALKS)
        c = m.tool("copy", text=EMAILS, what="14 addresses")
        return "Saved Team.csv and Talks.ics, and copied the 14 addresses. Paste them anywhere: one a line, in the order the page lists them."
    if "link:" in low:
        c = m.tool("copy", url=PAGE, title="Velmora festival", quote=QUOTE)
        return "Copied a link to the lantern walk's paragraph."
    if "thefile:" in low:
        saved = m.tool("save_file", name="Report.json", text='[{"a": 1}, {"a": 2}, {"a": 3}]')
        path = saved.splitlines()[0].removeprefix("Saved: ").rsplit(" (", 1)[0]
        c = m.tool("copy", file=path)
        return "Saved Report.json and copied the file."
    if "outside:" in low:
        a = m.tool("copy", file="/etc/hosts")
        b = m.tool("save_file", name="../../escape.csv", text="a,b\n")
        return f"[{a.splitlines()[0]}] [{b.splitlines()[0]}]"
    if "emails:" in low:
        c = m.tool("copy", text=EMAILS, what="14 addresses")
        return "Copied the 14 addresses on this page. Paste them anywhere: one a line, in the order the page lists them."
    return None


threading.Thread(target=read, daemon=True).start()
log("START", f"pid={os.getpid()}", "resume=" + resume)
out({"type": "system", "subtype": "init", "session_id": SID})
while True:
    msg, text = heard.get()
    if msg is None: break
    out(dict(msg, isReplay=True))
    log("HEARD", json.dumps(text))
    words = (text.rsplit("«", 1)[-1].split("»", 1)[0] if "«" in text else text).strip()
    m = Mcp()
    answer = act(m, text.lower()) or ("Heard: " + words[:200].replace("\n", " "))
    m.close()
    say(answer)
    out({"type": "result", "result": answer, "session_id": SID})
    log("ANSWERED", answer)
