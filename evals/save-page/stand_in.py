#!/usr/bin/env python3
# A stand-in Claude for evals/save-page/check.py: speaks Claude Code's
# stream-json and, by the words it is given, calls save_page through Yab's
# real MCP server, as a real agent would, logging every tool's answer.
#
#   "pdf"     save_page on the page asked about, as a PDF
#   "excel"   save_page as xlsx with no table named: the list comes back
#   "all"     save_page as xlsx, table all (a sheet each)
#   "csv"     save_page as csv, table 2
#   "book"    save_page with both article tabs, reader, one PDF
#   "markdown" save_page with both article tabs as one Markdown file
import json, os, queue, subprocess, sys, threading, time, uuid

args = sys.argv[1:]
if "--mcp-config" not in args:
    print(json.dumps({"loggedIn": True})); sys.exit(0)
LOG = open(os.environ.get("SAVE_PAGE_LOG", os.devnull), "a")
resume = args[args.index("--resume") + 1] if "--resume" in args else ""
SID = resume or "savepage-" + uuid.uuid4().hex[:8]
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
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "save-page", "version": "1"}})
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


threading.Thread(target=read, daemon=True).start()
log("START", f"pid={os.getpid()}", "resume=" + resume)
out({"type": "system", "subtype": "init", "session_id": SID})
while True:
    msg, text = heard.get()
    if msg is None: break
    out(dict(msg, isReplay=True))
    log("HEARD", json.dumps(text))
    # The person's own words, after Yab's framing.
    # The person's own words come first; the page's words, quoted after.
    words = (text.split("«", 1)[1].split("»", 1)[0] if "«" in text else text).strip()
    low = words.lower()
    m = Mcp()
    listed = m.tool("tabs")

    def tab_of(path):
        return next((line.split()[0] for line in listed.splitlines() if path in line), "")

    # The tab they asked on: the one Yab says it gave.
    given = text.split("their tab ", 1)[1].split(" ", 1)[0] if "their tab " in text else ""
    asked = next((p for p in ("/article-one", "/article-two", "/prices") if p in text.split("Its words", 1)[0]), "")
    tab = given or (tab_of(asked) if asked else "")
    if "book" in low:
        said = m.tool("save_page", tabs=[tab_of("/article-one"), tab_of("/article-two")], reader=True, format="pdf", title="Flight reading")
        answer = "Both articles are in one PDF, an outline entry each."
    elif "markdown" in low:
        said = m.tool("save_page", tabs=[tab_of("/article-one"), tab_of("/article-two")], format="md", title="Notes")
        answer = "Both articles are in one Markdown file."
    elif "excel" in low:
        said = m.tool("save_page", tab=tab, format="xlsx")
        answer = "There are three tables here. Which one?" if "tables" in said else "Saved the table."
    elif "all" in low:
        said = m.tool("save_page", tab=tab, format="xlsx", table="all")
        answer = "All three tables, a sheet each."
    elif "csv" in low:
        said = m.tool("save_page", tab=tab, format="csv", table="2")
        answer = "The second table as a CSV."
    elif "pdf" in low:
        said = m.tool("save_page", tab=tab, format="pdf")
        answer = "Here's the full article as a PDF."
    else:
        said, answer = "", "Heard: " + words[:200].replace("\n", " ")
    m.close()
    log("SAID", json.dumps(said))
    say(answer)
    out({"type": "result", "result": answer, "session_id": SID})
    log("ANSWERED", answer)
    continue
