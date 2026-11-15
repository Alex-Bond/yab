#!/usr/bin/env python3
"""Settings › Tabs with the sites kept awake, light and dark, and Add Site…'s
card: pictures drawn by Yab itself (winshot), no Screen Recording needed.

    evals/awake-sites/shots.py --bin .build/debug/Fast --out DIR
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sync"))
from check import Yab  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="yab-awake-sites-")
    yab = Yab(args.bin, scratch, "awake", "http://127.0.0.1:9")
    try:
        yab.start()
        for dark in (False, True):
            yab.bench(**{"do": "code", "act": "appearance", "dark": dark})
            for page in ("general", "tabs"):
                # The ui answer comes before the page is drawn; the census
                # after it waits until the main thread is free, so the time
                # is this page's. Timed on the ui call alone, General's cost
                # (it looked up the default browser while drawing, fixed
                # since) showed up as Tabs taking 10 to 20 s.
                began = time.time()
                yab.bench(wait=90, **{"do": "ui", "page": page, "settings": True})
                yab.bench(wait=90, do="census")
                print(page, "opened in", round(time.time() - began, 1), "s")
                time.sleep(1.2)
            # The row found as if typed in Settings' search, so the page
            # scrolls to it.
            print(yab.bench(wait=60, **{"do": "ui", "search": "keep these sites awake"}))
            time.sleep(1.5)
            name = os.path.join(out, f"tabs-{'dark' if dark else 'light'}.png")
            print(name, yab.bench(wait=60, **{"do": "winshot", "settings": True, "path": name}))
    finally:
        yab.stop()
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
