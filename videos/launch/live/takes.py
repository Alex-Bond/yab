#!/usr/bin/env python3
"""The films' live takes (docs/launch-videos.md), recorded on a Mac whose
screen is unlocked: on adhd, with the demo app installed there.

    swiftc -O -o rec rec.swift        once, the recorder (Screen Recording allowed for it)
    python3 takes.py                  every take into ~/yab-takes/*.mov
    python3 takes.py pip dust         some of them
    python3 takes.py --export DIR     ~/yab-takes → DIR/*.mp4 (30 fps), for public/takes

Each take builds its scene's world fresh, so a take can be run again.
The pointer is the Mac's own: nobody should be at it while this runs.
"""
import subprocess
import sys
import time
from pathlib import Path

import Quartz

from kit import CURRENT, OUT, W, b, click, clock, done, key, main_rect, move, open_take, record

CMD, OPT, SHIFT = Quartz.kCGEventFlagMaskCommand, Quartz.kCGEventFlagMaskAlternate, Quartz.kCGEventFlagMaskShift


def tab(world, piece):
    return next(t for t in b(world, {"do": "tabs"})["tabs"] if piece in t["url"])


def pip():
    """The video lifts out, goes on playing over another tab, shows its
    chapters under the pointer. The floater is parked inside the window first."""
    w = open_take("take-pip", "pip")
    x, y, ww, hh = main_rect()
    video, shop = tab(w, "youtube.com/watch"), tab(w, "nordbutik")
    b(w, {"do": "eval", "id": video["id"], "js": "(function(){var v=document.querySelector('video');v.play();"
          "var c=document.querySelector('.ytp-subtitles-button');if(c&&c.getAttribute('aria-pressed')!=='true')c.click();return 1})()"})
    time.sleep(2)
    b(w, {"do": "float", "action": "on"})
    b(w, {"do": "float", "action": "width", "x": 540})
    b(w, {"do": "float", "action": "place", "x": x + ww - 560, "y": 1440 - (y + hh) + 20})
    b(w, {"do": "float", "action": "toggle"})
    time.sleep(1.5)
    move(1700, 700, 0.3)
    p = record("pip", 16)
    at = clock()
    at(1.5); b(w, {"do": "float", "action": "on", "settle": 0.1})
    at(3.0); b(w, {"do": "select", "id": shop["id"]})
    at(5.5); b(w, {"do": "float", "action": "enter", "x": 270, "y": 150})
    for i in range(18):
        b(w, {"do": "float", "action": "move", "x": 50 + i * 25, "y": 20}); time.sleep(0.11)
    at(10.5); b(w, {"do": "float", "action": "move", "x": 270, "y": 150})
    at(12.0); b(w, {"do": "float", "action": "exit"})
    done(p)


def capture():
    """⇧⌘2 for real: the outline follows the pointer, ↑ takes the chart's
    box, a click lifts it off into the corner."""
    open_take("take-cap", "capture")
    x, y, ww, hh = main_rect()
    to = lambda fx, fy, dur: move(x + fx * ww, y + fy * hh, dur)  # where on Ledger's page, in its parts
    to(0.875, 0.26, 0.3)
    p = record("capture", 17)
    at = clock()
    at(1.2); key(19, SHIFT | CMD)
    at(2.4); to(0.72, 0.35, 0.7)
    at(3.3); to(0.55, 0.35, 0.6)
    at(4.1); to(0.41, 0.35, 0.6)
    at(5.0); to(0.65, 0.66, 0.9)
    at(6.4); key(126)
    at(7.6); click()
    at(15.5); key(53)
    done(p)


def devtools():
    w = open_take("take-dev", "devtools", prefs={"dev.side": "right"})
    move(900, 700, 0.4)
    p = record("devtools", 14)
    at = clock()
    at(1.5); key(34, OPT | CMD)
    at(5.5); b(w, {"do": "ui", "devpane": "network"})
    at(9.0); b(w, {"do": "ui", "devpane": "errors"})
    done(p)


def dust():
    """Clear on the line over today's tabs: they go to dust."""
    open_take("take-tabs", "tabs")
    x, y, _, _ = main_rect()
    move(700, 700, 0.4)
    p = record("dust", 10)
    at = clock()
    at(1.0); move(x + 124, y + 240, 0.8)
    at(2.4); move(x + 198, y + 238, 0.5)
    at(3.2); click()
    done(p)


def island():
    """Drift playing; away from its tab the island rises; pointed at, it opens."""
    w = open_take("take-island", "island")
    fog = tab(w, "morning-fog")
    b(w, {"do": "eval", "id": fog["id"], "js": "(function(){var b=document.querySelector('[data-play]')||document.getElementById('play');if(b)b.click();return 1})()"})
    time.sleep(3)
    other = next(t for t in b(w, {"do": "tabs"})["tabs"] if "drift" not in t["url"] and not t["pinned"])
    x, y, _, hh = main_rect()
    move(900, 700, 0.4)
    p = record("island", 14)
    at = clock()
    at(1.5); b(w, {"do": "select", "id": other["id"]})
    at(4.5); move(x + 84, y + hh - 20, 1.0)
    at(10.0); move(700, 800, 0.8)
    done(p)


def hello():
    """The notebook about Mira, written out as it opens."""
    w = open_take("take-hello", "hello")
    you = tab(w, "yab://you")
    move(900, 700, 0.4)
    p = record("hello", 20)
    at = clock()
    at(1.5); b(w, {"do": "select", "id": you["id"]})
    done(p)


def agent():
    """A real run of Claude: the task typed in ⌘T, its chat in the column,
    its own tabs. Needs a claude the app can start (YAB_AGENT_CLAUDE, the
    claude-real wrapper in .claude/skills/adhd)."""
    claude = str(Path.home() / ".cache/yab-morning/claude-real")
    w = open_take("take-agent", "agent", env={"YAB_AGENT_CLAUDE": claude})
    words = "find the best direct flight to Lisbon on my dates, I want a window seat"
    move(900, 700, 0.4)
    p = record("agent", 160)
    at = clock()
    at(1.5); b(w, {"do": "box", "act": "t"})
    at(2.5)
    for i in range(0, len(words), 2):  # box type adds to what is there
        b(w, {"do": "box", "act": "type", "text": words[i:i + 2]}); time.sleep(0.05)
    at(10.0); b(w, {"do": "box", "act": "key", "keys": "return"})
    t0, picked = time.time(), False
    while time.time() - t0 < 145:
        tabs = [t for t in b(w, {"do": "tabs"})["tabs"] if t.get("agent")]
        if tabs and not picked and time.time() - t0 > 12:
            pick = next((t for t in tabs if "google.com" in t["url"]), tabs[0])
            b(w, {"do": "select", "id": pick["id"]}); picked = True
        time.sleep(3)
    done(p)


TAKES = {"pip": pip, "capture": capture, "devtools": devtools, "dust": dust, "island": island, "hello": hello, "agent": agent}
# What of each take the films play, in seconds (the rest is lead-in).
CUTS = {"agent": [(10.2, 14.2), (38.5, 42.7)]}


def export(target):
    target.mkdir(parents=True, exist_ok=True)
    for name in TAKES:
        source = OUT / (name + ".mov")
        if not source.exists():
            continue
        out = target / (name + ".mp4")
        if name in CUTS:
            parts = "".join("[0:v]trim=start=%s:end=%s,setpts=PTS-STARTPTS,fps=30[p%d];" % (a, z, i) for i, (a, z) in enumerate(CUTS[name]))
            joined = "".join("[p%d]" % i for i in range(len(CUTS[name])))
            args = ["-filter_complex", parts + joined + "concat=n=%d:v=1:a=0,format=yuv420p[v]" % len(CUTS[name]), "-map", "[v]"]
        else:
            args = ["-vf", "fps=30,format=yuv420p", "-c:a", "aac", "-b:a", "192k"]
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(source), *args, "-c:v", "libx264", "-crf", "16",
                        "-movflags", "+faststart", str(out)], check=True)
        print(out)


def main():
    args = sys.argv[1:]
    if args[:1] == ["--export"]:
        return export(Path(args[1]))
    for name in args or list(TAKES):
        print(name, flush=True)
        TAKES[name]()
        W.quit_world(CURRENT["world"])


if __name__ == "__main__":
    main()
