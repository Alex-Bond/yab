#!/usr/bin/env python3
"""Yab's own reload over something typed (docs: Asks.swift, `.reload`): a
comment box with words in it, then the site's blocker switched in Site
Controls. Pictures drawn by Yab itself (winshot with the page), no Screen
Recording needed. A second page with nothing typed reloads at once.

    evals/reload-ask/shots.py --bin .build/debug/Fast --out DIR
"""
import argparse
import functools
import http.server
import json
import os
import shutil
import socketserver
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sync"))
from check import Yab  # noqa: E402

PAGE = """<!doctype html><meta charset=utf-8><title>Fix the cache key · Pull Request #412</title>
<style>
body{font:14px -apple-system,system-ui;margin:0;background:#fff;color:#1f2328}
header{border-bottom:1px solid #d1d9e0;padding:16px 32px;background:#f6f8fa}
h1{font-size:24px;font-weight:400;margin:0}
main{max-width:760px;margin:24px auto;padding:0 32px}
.c{border:1px solid #d1d9e0;border-radius:6px;margin-bottom:16px}
.c b{display:block;background:#f6f8fa;border-bottom:1px solid #d1d9e0;padding:8px 16px;font-weight:600}
.c p{padding:0 16px}
textarea{box-sizing:border-box;width:100%;height:140px;border:0;padding:12px 16px;font:14px -apple-system;resize:none;outline:none}
button{margin:8px 16px;float:right;background:#1f883d;color:#fff;border:0;border-radius:6px;padding:6px 14px;font-weight:600}
</style>
<header><h1>Fix the cache key <span style="color:#59636e">#412</span></h1></header>
<main>
<div class=c><b>mira commented</b><p>The key leaves out the locale, so two languages share one entry.</p></div>
<div class=c><b>Add a comment</b><textarea placeholder="Leave a comment" autofocus></textarea><div style="overflow:hidden"><button>Comment</button></div></div>
</main>
<script>window.__born = Date.now(); window.__trusted = []; document.addEventListener("input", e => __trusted.push(e.isTrusted), true)</script>
"""


def serve(root):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *a: None
    server = socketserver.TCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--label", default="")
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="yab-reload-ask-")
    site = os.path.join(scratch, "site")
    os.makedirs(site)
    with open(os.path.join(site, "pr.html"), "w") as f:
        f.write(PAGE)
    server = serve(site)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yab = Yab(args.bin, scratch, "reload", "http://127.0.0.1:9")
    # The probe app is the binary alone; the page scripts, forms.js among
    # them, which says whether a page holds a draft, come from the build's.
    built = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.bin))), "Resources", "PageScripts")
    shutil.copytree(built if os.path.isdir(built) else os.path.join(HERE, "..", "..", "Resources", "PageScripts"),
                    os.path.join(yab.app, "Contents", "Resources", "PageScripts"))
    report = {}
    try:
        yab.start()
        yab.bench(do="resize", width=1280, height=820, steps=1)

        def born(tab):
            return yab.bench(do="eval", id=tab, js="window.__born").get("value")

        def value(tab):
            return yab.bench(do="eval", id=tab, js="document.querySelector('textarea').value").get("value")

        # Nothing typed: the switch reloads at once, as before.
        def front(url):
            tab = yab.bench(do="open", url=url, plain=True)["id"]
            yab.bench(do="select", id=tab)
            yab.bench(do="ui", closeField=True)
            time.sleep(2.5)
            return tab

        empty = front(base + "/pr.html?empty")
        first = born(empty)
        yab.bench(do="shield", toggle="127.0.0.1", id=empty)
        time.sleep(2.5)
        report["empty_reloaded"] = born(empty) != first
        yab.bench(do="shield", pause="127.0.0.1", on=False)

        # Words in the comment box, typed by hand: the switch asks first.
        tab = front(base + "/pr.html")
        yab.bench(do="eval", id=tab, js="document.querySelector('textarea').focus()")
        yab.bench(do="key", id=tab, text="Good catch. I'll add the locale to the key and a test for two languages")
        time.sleep(2)
        report["typed"] = value(tab)
        report["trusted"] = yab.bench(do="eval", id=tab, js="JSON.stringify(window.__trusted.slice(0, 3))").get("value")
        report["unsaved"] = yab.bench(do="eval", id=tab, world="yab",
                                      js="window.__yabForms ? String(window.__yabForms.unsaved()) : 'no forms'")
        first = born(tab)
        yab.bench(do="winshot", page=True, path=os.path.join(out, f"{args.label}1-typed.png"))
        yab.bench(do="shield", toggle="127.0.0.1", id=tab)
        time.sleep(2.5)
        yab.bench(do="winshot", page=True, path=os.path.join(out, f"{args.label}2-switched.png"))
        report["typed_reloaded"] = born(tab) != first
        report["typed_kept"] = value(tab)
        report["asks"] = yab.bench(do="ui", ask="list").get("asks")
        # Later: the words stay, the page as it was.
        yab.bench(do="ui", ask="no")
        time.sleep(1.5)
        report["later_reloaded"] = born(tab) != first
        report["later_kept"] = value(tab)
        # Asked again, Reload: the page loads again, the words go.
        yab.bench(do="shield", toggle="127.0.0.1", id=tab)
        time.sleep(1.5)
        yab.bench(do="ui", ask="yes")
        time.sleep(2.5)
        report["reload_reloaded"] = born(tab) != first
        report["reload_kept"] = value(tab)
    finally:
        print(json.dumps(report, indent=1))
        with open(os.path.join(out, f"{args.label}report.json"), "w") as f:
            json.dump(report, f, indent=1)
        yab.stop()
        server.shutdown()
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
