#!/usr/bin/env python3
"""Pictures of Settings › Tabs' "Always keep these sites awake" in a test
world, light and dark: the list at rest, and a row under the pointer with
its remove minus. --page, --spot and --rows point it at another list with
the same minus (Settings › Search's Fallback Commands: --page search --spot
search-suggest --rows 120,160,200,240).

    evals/awake-sites/shot.py --bin PATH --out DIR   (a display farm job, --needs capture,accessibility,pointer)
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sync"))
from check import Yab  # noqa: E402
sys.path.insert(0, os.path.join(HERE, ".."))
import probe_capture  # noqa: E402

POINTER = os.path.join(HERE, "..", "window-tiling", "pointer.py")


def hand_python():
    for py in [sys.executable, "/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]:
        if py and subprocess.run([py, "-c", "import Quartz, AppKit"], capture_output=True).returncode == 0:
            return py
    raise RuntimeError("no python with PyObjC")


PY = hand_python()


def hand(*words):
    out = subprocess.run([PY, POINTER, *map(str, words)], capture_output=True, text=True)
    return json.loads(out.stdout) if out.stdout.strip().startswith("{") else {"error": out.stderr[-300:]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--page", default="tabs")
    parser.add_argument("--spot", default="awake-sites")
    parser.add_argument("--rows", default="70,160,385", help="rows' heights from the window's top")
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="yab-awake-sites-")
    yab = Yab(args.bin, scratch, "awake", "http://127.0.0.1:9")
    try:
        yab.start()
        pid = yab.pid
        for dark in (False, True):
            tone = "dark" if dark else "light"
            yab.bench(**{"do": "code", "act": "appearance", "dark": dark})
            yab.bench(**{"do": "ui", "page": args.page, "settings": True})
            time.sleep(1.2)
            yab.bench(**{"do": "ui", "spot": args.spot})
            # The wash of the found row gone.
            time.sleep(2.5)
            windows = yab.bench(**{"do": "ui", "windows": True}).get("windows", [])
            settings = next(w for w in windows if "Settings" in w["kind"] or w["title"] == "Settings")
            frame = next(w["frame"] for w in hand("windows", pid)["windows"] if w["number"] == settings["id"])
            x, y, w, h = frame
            # In front of other jobs' windows on a shared screen, or the
            # pointer lands on them.
            subprocess.run([PY, "-c", "import AppKit,sys; AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(int(sys.argv[1])).activateWithOptions_(3)", str(pid)])
            yab.bench(**{"do": "ui", "settings": True})
            time.sleep(0.8)
            hand("move", x + w + 40, y + h + 40)
            time.sleep(0.6)
            print(tone, "rest", probe_capture.picture(pid, os.path.join(out, f"rest-{tone}.png"), window_id=settings["id"]))
            # The window made key by a press on a row's empty middle (a row
            # takes no press), as hover is heard only in the active window;
            # then the pointer onto rows the shot showed at rest.
            rows = [int(r) for r in args.rows.split(",")]
            for n, dy in enumerate(rows):
                if n == 0:
                    print("under", [(t["owner"], t["name"]) for t in hand("top", x + w * 0.62, y + dy).get("top", [])][:3])
                    print("click", hand("click", x + w * 0.62, y + dy))
                hand("glide", x + w * 0.62, y + dy - 25, x + w * 0.62, y + dy, 8)
                time.sleep(0.6)
                print(tone, "hover", n, probe_capture.picture(pid, os.path.join(out, f"hover-{tone}-{n}.png"), window_id=settings["id"]))
            # Onto the first row's button itself, for its tip.
            hand("glide", x + w * 0.62, y + rows[0], x + 718, y + rows[0], 8)
            time.sleep(1.8)
            print(tone, "tip", probe_capture.picture(pid, os.path.join(out, f"tip-{tone}.png"), window_id=settings["id"]))
            hand("move", x + w + 40, y + h + 40)
    finally:
        yab.stop()
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
