#!/usr/bin/env python3
"""Use an API Key (docs/agents.md, Connect): Settings › AI's way in with the
key's field, a key turned down, and a key taken, in a HOME of its own with a
stand-in claude that writes down the ANTHROPIC_API_KEY it was run with.

    evals/agent-key/run.py --bin PATH --out DIR   (a display farm job, --needs capture)

Pictures are Settings' window through ScreenCaptureKit (--needs capture):
a winshot of Settings leaves this SwiftUI page blank.
Prints one JSON line per check and exits 1 if any failed.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sync"))
from check import Yab  # noqa: E402
sys.path.insert(0, os.path.join(HERE, ".."))
import probe_capture  # noqa: E402

KEY = "sk-ant-api03-probe-0000000000000000"

# Signed out of any plan; `mcp add` writes ~/.claude.json as Claude Code
# does, and every run notes the key it was given.
STANDIN = """#!/bin/bash
echo "${ANTHROPIC_API_KEY:-none} $*" >> "$HOME/claude-runs.log"
case "$1 $2" in
  "auth status") echo '{"loggedIn": false}'; exit 1 ;;
  "mcp add")
    /usr/bin/python3 - "$HOME/.claude.json" "$5" "$7" <<'PY'
import json, os, sys
path, name, command = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path)) if os.path.exists(path) else {}
data.setdefault("mcpServers", {})[name] = {"type": "stdio", "command": command, "args": ["mcp"]}
json.dump(data, open(path, "w"))
PY
    exit 0 ;;
esac
exit 0
"""


class KeyYab(Yab):
    """The sync check's probe app, in a HOME of its own."""

    def __init__(self, binary, scratch, label, home, check, claude):
        super().__init__(binary, scratch, label, "http://127.0.0.1:9")
        self.home, self.check, self.claude = home, check, claude

    def start(self):
        subprocess.call(["open", "-g", "-n", "-j", "--env", f"YAB_PROBE={self.world}", "--env", f"FAST_PROBE={self.world}",
                         "--env", f"HOME={self.home}", "--env", f"YAB_AGENT_CLAUDE={self.claude}",
                         "--env", f"YAB_AGENT_KEY={KEY}", "--env", f"YAB_AGENT_KEY_CHECK={self.check}", "-a", self.app])
        end = time.time() + 30
        while time.time() < end:
            try:
                self.pid = self.bench(do="census")["pid"]
                return
            except OSError:
                time.sleep(0.2)
        raise AssertionError("no bench socket after 30 s")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    failed = []

    def check(ok, what, **seen):
        print(json.dumps({"ok": bool(ok), "check": what, **seen}), flush=True)
        if not ok:
            failed.append(what)

    for verdict in ("refused", "taken"):
        scratch = tempfile.mkdtemp(prefix=f"yab-agent-key-{verdict}-")
        home = os.path.join(scratch, "home")
        os.makedirs(home)
        claude = os.path.join(scratch, "claude")
        with open(claude, "w") as f:
            f.write(STANDIN)
        os.chmod(claude, 0o755)
        yab = KeyYab(args.bin, scratch, verdict, home, verdict, claude)
        try:
            yab.start()
            agents = lambda command: yab.bench(do="ui", agents=command)
            yab.bench(do="ui", page="ai", settings=True)
            end = time.time() + 20
            while time.time() < end and agents("page")["found"][0] == "":
                time.sleep(0.5)
            time.sleep(2)
            def shot(name):
                windows = yab.bench(do="ui", windows=True).get("windows", [])
                settings = next((w for w in windows if "Settings" in w.get("kind", "") or w.get("title") == "Settings"), None)
                if settings is None:
                    return print(json.dumps({"shot": name, "error": "no Settings window", "windows": windows}))
                print(json.dumps({"shot": name, "got": str(probe_capture.picture(yab.pid, os.path.join(out, name + ".png"), window_id=settings["id"]))}))

            if verdict == "refused":
                shot("1-way-in")
            state = agents("usekey:claude")
            check(state["keyFor"] == "claude", "the key's field opens", state=state["keyFor"])
            time.sleep(1)
            shot(f"2-key-field-{verdict}")
            agents("key:claude")
            end = time.time() + 40
            state = agents("page")
            while time.time() < end and (state["flow"] not in ("page",) and not state["flow"].startswith("asking")):
                time.sleep(0.3)
                state = agents("page")
            time.sleep(1)
            shot(f"3-after-{verdict}")
            runs = open(os.path.join(home, "claude-runs.log")).read() if os.path.exists(os.path.join(home, "claude-runs.log")) else ""
            if verdict == "refused":
                check(state["trouble"] == "Anthropic didn’t take this key. Check it and paste it again.", "a refused key says so", trouble=state["trouble"])
                check(state["keyed"] == [], "a refused key is not kept", keyed=state["keyed"])
                check(KEY not in runs, "no claude ran with a refused key")
            else:
                check(state["flow"].startswith("asking"), "a taken key connects", flow=state["flow"], trouble=state["trouble"])
                check(state["claude"] is True, "Yab's tools are in place", claude=state["claude"])
                check("claude" in state["keyed"], "the key is kept", keyed=state["keyed"])
                check(state["signedIn"].get("claude") is True, "Claude reads as signed in", signedIn=state["signedIn"])
                check(state["envKey"] is True, "the env every claude gets holds the key")
                mcp = [line for line in runs.splitlines() if " mcp add " in f" {line} "]
                check(mcp and all(line.startswith(KEY + " ") for line in mcp), "claude ran with the key in its env", runs=mcp[-1:])
                agents("finish")
                agents("removekey:claude")
                end = time.time() + 20
                while time.time() < end and agents("page")["keyed"]:
                    time.sleep(0.3)
                time.sleep(2)
                state = agents("page")
                check(state["keyed"] == [], "Remove Key takes it away", keyed=state["keyed"])
                check(state["envKey"] is False, "the env holds it no more")
                # Signed in or not is the Mac's own Claude Code keychain item now.
                print(json.dumps({"after-remove-signedIn": state["signedIn"]}))
        finally:
            yab.stop()

    print(json.dumps({"failed": failed}))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
