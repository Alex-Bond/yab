#!/usr/bin/env python3
# A stand-in Claude for evals/close-tabs/check.py: speaks Claude Code's
# stream-json and does what an agent should with "close my YouTube tabs",
# "close my duplicate tabs" and "close what I haven't used in a week": reads
# native_context's tabs, closes the ones that match with one native_apply
# tabs.close, and answers in one line. Logs what it heard and did.
import datetime, json, os, subprocess, sys, uuid

args = sys.argv[1:]
if "--mcp-config" not in args:
    print(json.dumps({"loggedIn": True})); sys.exit(0)
LOG = open(os.environ.get("CLOSE_TABS_LOG", os.devnull), "a")
SID = (args[args.index("--resume") + 1] if "--resume" in args else "") or "close-" + uuid.uuid4().hex[:8]
server = next(iter(json.loads(args[args.index("--mcp-config") + 1])["mcpServers"].values()))
P = "mcp__yab-browser__"


def out(o): print(json.dumps(o), flush=True)
def log(*a): print(*a, file=LOG, flush=True)
def say(words): out({"type": "assistant", "message": {"id": "msg_" + uuid.uuid4().hex[:12], "content": [{"type": "text", "text": words}]}})


class Mcp:
    def __init__(self):
        self.p = subprocess.Popen([server["command"]] + server.get("args", []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=LOG, text=True)
        self.n = 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "close-tabs", "version": "1"}})
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
        log("TOOL", tool, json.dumps(a)[:300], "->", said.replace("\n", " | ")[:600])
        out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": said[:2000], "is_error": bool(res.get("isError"))}]}})
        try: return json.loads(said)
        except ValueError: return {"text": said}

    def close(self):
        try: self.p.stdin.close(); self.p.terminate()
        except Exception: pass


def pick(words, tabs):
    loose = [t for t in tabs if not t.get("pinned") and not t.get("kept")]
    if "youtube" in words:
        return ("YouTube tab", "YouTube tabs"), [t for t in loose if "youtube.com" in t.get("url", "")]
    if "duplicate" in words:
        return ("duplicate tab", "duplicate tabs"), [t for t in loose if t.get("duplicateOf")]
    if "week" in words:
        now = datetime.datetime.now(datetime.timezone.utc)
        old = lambda t: (now - datetime.datetime.fromisoformat(t["lastUsed"].replace("Z", "+00:00"))).days >= 7
        return ("tab you haven't used in a week", "tabs you haven't used in a week"), [t for t in loose if t.get("lastUsed") and old(t)]
    return None, []


out({"type": "system", "subtype": "init", "session_id": SID})
for line in iter(sys.stdin.readline, ""):
    try: msg = json.loads(line)
    except ValueError: continue
    if msg.get("type") != "user": continue
    out(dict(msg, isReplay=True))
    content = msg["message"]["content"]
    text = content if isinstance(content, str) else "".join(c.get("text", "") for c in content if isinstance(c, dict))
    words = (text.rsplit("«", 1)[-1].split("»", 1)[0] if "«" in text else text).strip().lower()
    log("HEARD", json.dumps(words), "brief-mentions-tabs.close:", "tabs.close" in text)
    m = Mcp()
    context = m.tool("native_context", limit=50)
    what, going = pick(words, context.get("tabs", []))
    if not going:
        answer = "No tabs to close."
    else:
        done = m.tool("native_apply", action="tabs.close", target={"kind": "space", "id": context.get("activeSpaceId", "")},
                      arguments={"tabs": [t["id"] for t in going]}, requestId=uuid.uuid4().hex)
        n = done.get("closed", 0)
        answer = f"Closed {n} {what[n != 1]}." if done.get("status") == "verified" else f"Couldn't close them: {done}"
    m.close()
    say(answer)
    out({"type": "result", "result": answer, "session_id": SID})
    log("ANSWERED", answer)
