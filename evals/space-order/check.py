#!/usr/bin/env python3
"""Any space moves, the first one too: Personal taken to the bottom stays
there after Yab starts again, and Settings › Spaces is pictured with its
rows (44 tall, hairlines from the mark), light and dark, by Yab itself.

    evals/space-order/check.py --bin .build/debug/Fast --out DIR
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


def ask(yab, **request):
    """A bench call; an empty answer says whether Yab is still running."""
    try:
        return yab.bench(wait=30, **request)
    except ValueError:
        alive = subprocess.call(["ps", "-p", str(yab.pid)], stdout=subprocess.DEVNULL) == 0
        raise AssertionError(f"no answer to {request}; Yab {'still running' if alive else 'gone'}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="yab-space-order-")
    yab = Yab(args.bin, scratch, "order", "http://127.0.0.1:9")
    failures = []
    try:
        yab.start()
        yab.bench(do="space", on=True)
        time.sleep(1)
        for name in ("Gross", "Work"):
            print(name, ask(yab, do="space", new=name))
            time.sleep(1.5)
        made = ask(yab, do="space")["spaces"]
        print("made:", made)
        moved = ask(yab, do="space", move="Personal", place=len(made) - 1)["spaces"]
        print("Personal to the bottom:", moved)
        if moved[-1] != "Personal":
            failures.append(f"Personal did not move: {moved}")
        yab.quit()
        yab.start()
        again = ask(yab, do="space")["spaces"]
        print("after a new start:", again)
        if again != moved:
            failures.append(f"order not kept across a start: {again} != {moved}")
        back = ask(yab, do="space", move="Personal", place=1)["spaces"]
        print("Personal to the middle:", back)
        if back[1] != "Personal":
            failures.append(f"Personal did not move back up: {back}")
        for dark in (False, True):
            yab.bench(**{"do": "code", "act": "appearance", "dark": dark})
            yab.bench(wait=90, **{"do": "ui", "page": "spaces", "settings": True})
            yab.bench(wait=90, do="census")
            time.sleep(1.5)
            name = os.path.join(out, f"spaces-{'dark' if dark else 'light'}.png")
            print(name, yab.bench(wait=60, **{"do": "winshot", "settings": True, "path": name}))
    finally:
        yab.stop()
        shutil.rmtree(scratch, ignore_errors=True)
    for failure in failures:
        print("FAIL", failure)
    print("PASS" if not failures else f"{len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
