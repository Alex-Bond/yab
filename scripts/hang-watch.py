#!/usr/bin/env python3
"""Catch a stack the next time the installed Yab freezes.

Watches the installed yab and its YabCore page engine from outside (no
socket, no injection) and runs `sample` on the stuck process while it is
still stuck. Two signals:

- YabCore holds its "Capturing" power assertion (taken around every tab
  capture, normally released within half a second) for longer than
  CAPTURE_STALL seconds. That is how the 2026-11-04 12:23:49 freeze
  looked: an 8 s assertion while the main thread logged nothing.
- A process's main thread burns at least BUSY_SHARE of a CPU for BUSY_WINDOW
  seconds straight.

Each catch writes a folder in ~/Library/Logs/Yab/hangs/ with the sample,
the last 40 s of the process's log and why it fired. Runs until killed:

    nohup scripts/hang-watch.py > ~/Library/Logs/Yab/hangs/watch.log 2>&1 &
"""
import datetime
import json
import os
import re
import subprocess
import threading
import time

APP = "/Applications/yab.app/Contents/MacOS/"
OUT = os.path.expanduser("~/Library/Logs/Yab/hangs")
CAPTURE_STALL = 2.5
BUSY_WINDOW = 3.0
BUSY_SHARE = 0.85
SAMPLE_SECONDS = 6
COOLDOWN = 60.0

lock = threading.Lock()
last_catch = {}
open_captures = {}  # assertion id -> created (monotonic)


def say(*parts):
    print(datetime.datetime.now().strftime("%H:%M:%S"), *parts, flush=True)


def pid_of(binary):
    """PID of the installed binary (YabCore with flags, yab without)."""
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        exe = command.split(" --", 1)[0].strip()
        if exe == APP + binary:
            return int(pid)
    return None


def main_thread_seconds(pid):
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines()
    if len(out) < 2:
        return None
    times = re.findall(r"(\d+):(\d+\.\d+)", out[1])
    if len(times) < 2:
        return None
    return sum(int(m) * 60 + float(s) for m, s in times[:2])


def catch(name, pid, why):
    with lock:
        now = time.monotonic()
        if now - last_catch.get(name, -COOLDOWN) < COOLDOWN:
            return
        last_catch[name] = now
    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    folder = os.path.join(OUT, f"{stamp}-{name}")
    os.makedirs(folder, exist_ok=True)
    say(f"catch {name} pid {pid}: {why} -> {folder}")
    with open(os.path.join(folder, "why.txt"), "w") as f:
        f.write(f"{name} pid {pid}\n{why}\n")
    subprocess.run(["sample", str(pid), str(SAMPLE_SECONDS), "-mayDie", "-file",
                    os.path.join(folder, "sample.txt")], capture_output=True)
    with open(os.path.join(folder, "log.txt"), "w") as f:
        subprocess.run(["/usr/bin/log", "show", "--last", "40s", "--style", "compact", "--info",
                        "--predicate", f"processID == {pid}"], stdout=f, stderr=subprocess.STDOUT)
    say(f"saved {folder}")


def watch_captures():
    """Follow powerd's log for YabCore's Capturing assertions."""
    predicate = ('process == "powerd" AND eventMessage CONTAINS "YabCore" '
                 'AND eventMessage CONTAINS "Capturing"')
    while True:
        stream = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--predicate", predicate],
                                  stdout=subprocess.PIPE, text=True)
        for line in stream.stdout:
            try:
                message = json.loads(line).get("eventMessage", "")
            except ValueError:
                continue
            found = re.search(r"\bid:(\d+)", message)
            if not found:
                continue
            with lock:
                if " Created " in message:
                    open_captures[found.group(1)] = time.monotonic()
                elif " Released " in message:
                    open_captures.pop(found.group(1), None)
        say("log stream ended, restarting")
        time.sleep(2)


def main():
    os.makedirs(OUT, exist_ok=True)
    threading.Thread(target=watch_captures, daemon=True).start()
    say("watching yab and YabCore")
    history = {}  # name -> list of (monotonic, main thread seconds)
    while True:
        now = time.monotonic()
        core = pid_of("YabCore")
        with lock:
            stale = [(k, now - t) for k, t in open_captures.items() if now - t > CAPTURE_STALL]
            for key, _ in stale:
                open_captures.pop(key, None)
        if core and stale:
            held = max(age for _, age in stale)
            threading.Thread(target=catch, args=("YabCore", core,
                             f"Capturing assertion held {held:.1f} s"), daemon=True).start()
        for name in ("yab", "YabCore"):
            pid = core if name == "YabCore" else pid_of("yab")
            if not pid:
                history.pop(name, None)
                continue
            spent = main_thread_seconds(pid)
            if spent is None:
                continue
            points = [p for p in history.get(name, []) if p[2] == pid and now - p[0] <= BUSY_WINDOW + 0.6]
            points.append((now, spent, pid))
            history[name] = points
            first = points[0]
            span = now - first[0]
            if span >= BUSY_WINDOW and (spent - first[1]) / span >= BUSY_SHARE:
                share = (spent - first[1]) / span
                threading.Thread(target=catch, args=(name, pid,
                                 f"main thread {share:.0%} busy for {span:.1f} s"), daemon=True).start()
                history[name] = []
        time.sleep(0.5)


if __name__ == "__main__":
    main()
