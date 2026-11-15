#!/usr/bin/env python3
"""A space's icon picker in Settings (IconPicker with `space`): open off the
well of a new space, light and dark, with every emoji under the space's
offered ones; "boat" typed finds the sailboat; an emoji typed is picked
and closes it. Pictures of the screen where the popover is (screencapture).

    ./farm exec --display --needs capture -- evals/space-icon-picker/run.sh
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sync"))
from check import Yab  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--bin", required=True)
parser.add_argument("--out", required=True)
args = parser.parse_args()
out = os.path.abspath(args.out)
os.makedirs(out, exist_ok=True)
scratch = tempfile.mkdtemp(prefix="yab-space-icon-")
yab = Yab(args.bin, scratch, "icons", "http://127.0.0.1:9")
failures = []


def popovers():
    return yab.bench(do="popovers").get("popovers", [])


def open_picker():
    """Clicks down the right of the page till the well's popover is up."""
    # The well is the Icon row's control, at the right of the page and
    # above the Look row's dot, which has a popover of its own.
    for y in range(120, 420, 10):
        for x in range(900, 380, -24):
            yab.bench(do="settingsclick", x=x, y=y)
            time.sleep(0.25)
            up = popovers()
            if up:
                print("picker up after a click at", x, y, up)
                return up[-1]
    return None


def shot(name):
    up = popovers()
    if not up:
        failures.append(f"{name}: no popover")
        return
    # The screen where the popover is: a layer render draws its glass
    # wrong, so the screen itself (Screen Recording, --needs capture).
    f = up[-1]
    region = "%d,%d,%d,%d" % (f["x"] - 24, f["y"] - 24, f["w"] + 48, f["h"] + 48)
    path = os.path.join(out, name + ".png")
    done = subprocess.run(["screencapture", "-x", "-R" + region, path], capture_output=True, text=True)
    print(name, region, done.returncode, done.stderr.strip())
    # And the popover's window as AppKit draws it, whole wherever it stands.
    print(yab.bench(wait=60, do="winshot", window=f["number"], print=True, path=os.path.join(out, name + "-drawn.png")))


try:
    yab.start()
    yab.bench(do="space", on=True)
    time.sleep(1)
    for dark in (False, True):
        look = "dark" if dark else "light"
        yab.bench(**{"do": "code", "act": "appearance", "dark": dark})
        yab.bench(do="ui", look=look)
        yab.bench(wait=90, **{"do": "ui", "page": "spaces", "settings": True, "item": "new"})
        time.sleep(2)
        yab.bench(wait=60, do="winshot", settings=True, path=os.path.join(out, f"0-page-{look}.png"))
        if not open_picker():
            failures.append(f"{look}: the well opened no popover")
            continue
        time.sleep(1)
        shot(f"1-open-{look}")
        yab.bench(do="popovers", type="boat")
        time.sleep(1.2)
        shot(f"2-boat-{look}")
        yab.bench(do="popovers", key="esc")
        yab.bench(do="popovers", key="esc")
        time.sleep(0.8)
    # An emoji typed is the one picked: the picker goes.
    if open_picker():
        yab.bench(do="popovers", type="⛵")
        time.sleep(1)
        if popovers():
            failures.append("an emoji typed left the picker up")
        yab.bench(wait=60, do="winshot", settings=True, path=os.path.join(out, "3-picked.png"))
finally:
    yab.stop()
    shutil.rmtree(scratch, ignore_errors=True)
for failure in failures:
    print("FAIL", failure)
print("PASS" if not failures else f"{len(failures)} failed")
sys.exit(1 if failures else 0)
