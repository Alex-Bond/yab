#!/usr/bin/env python3
"""Settings' sidebar and a page's top in a test world, light and dark: the
pen-drawn page tiles (PenArt) as they ship.

    evals/settings-icons/shots.py --bin .build/debug/Fast --out DIR
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
sys.path.insert(0, os.path.join(HERE, ".."))
import probe_capture  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="yab-settings-icons-")
    yab = Yab(args.bin, scratch, "icons", "http://127.0.0.1:9")
    try:
        yab.start()
        for dark in (False, True):
            yab.bench(**{"do": "code", "act": "appearance", "dark": dark})
            for page in ("privacy", "passwords", "autofill", "about"):
                yab.bench(**{"do": "ui", "page": page, "settings": True})
                time.sleep(1.2)
                name = f"{page}-{'dark' if dark else 'light'}.png"
                # A layer render of Settings comes out blank: the window
                # itself, by its number, from the screen.
                windows = yab.bench(**{"do": "ui", "windows": True}).get("windows", [])
                settings = next((w for w in windows if "Settings" in w["kind"] or w["title"] == "Settings"), None)
                # Its pid as it says (bench census): a pgrep for the path
                # found nothing where the temp folder runs as /private/var.
                pid = yab.pid
                print(name, probe_capture.picture(int(pid), os.path.join(out, name), window_id=settings["id"]) if settings else windows)
    finally:
        yab.stop()
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
