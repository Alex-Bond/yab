"""Live takes: a demo scene (demos/) opened in front of an unlocked screen,
driven through its bench socket and the real pointer and keys, recorded
with rec (ScreenCaptureKit, 60 fps, no cursor, the system's sound).
takes.py says which takes the films use and how each is played."""
import json, os, subprocess, sys, time
from pathlib import Path
KIT = Path(__file__).resolve().parents[3]  # the repo, or a copy of demos/ and evals/mail beside live/
sys.path.insert(0, str(KIT / "demos"))
import world as W  # noqa
import persona as P  # noqa
from scenes import SCENES  # noqa
OUT = Path.home() / "yab-takes"
OUT.mkdir(exist_ok=True)
REC = Path(__file__).resolve().parent / "rec"


def b(world, req, timeout=60):
    return W.bench(world, req, timeout=timeout)


# Another session's probe may hold the right of the screen (adhd's test
# screen is shared): the takes stand in its left part.
W.screen_frame = lambda: [0, 40, 1416, 845, 2560, 1440]


def open_take(world, scene, size=(1340, 838), **change):
    s = dict(SCENES[scene]); s.update(change)
    W.build(world, s, size=size)
    CURRENT["world"] = world
    time.sleep(4)
    front()
    time.sleep(1)
    return world


CURRENT = {"world": None}


def windows(pid=None):
    import Quartz
    pid = pid or (W.pid_of(CURRENT["world"]) if CURRENT["world"] else None)
    out = []
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
        if (pid and w.get("kCGWindowOwnerPID") == pid) or (not pid and w.get("kCGWindowOwnerName") in ("Yab", "yab")):
            r = w["kCGWindowBounds"]
            out.append((w.get("kCGWindowNumber"), int(r["X"]), int(r["Y"]), int(r["Width"]), int(r["Height"]), w.get("kCGWindowLayer")))
    return out


def front():
    pid = W.pid_of(CURRENT["world"])
    # AppKit, not System Events: no Apple event, so no "wants access to
    # control" dialog over the take.
    import AppKit
    app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
    if app: app.activateWithOptions_(AppKit.NSApplicationActivateIgnoringOtherApps)
    time.sleep(0.4)


def main_rect():
    ws = [w for w in windows() if w[4] > 500 and w[5] == 0]
    _, x, y, w, h, _ = max(ws, key=lambda w: w[3] * w[4])
    return x, y, w, h


def record(name, seconds, rect=None, audio=True):
    x, y, w, h = rect or main_rect()
    args = [str(REC), str(OUT / (name + ".mov")), str(x), str(y), str(w), str(h), str(seconds)]
    if not audio: args.append("--no-audio")
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(0.8)
    return p


def done(p):
    out, _ = p.communicate()
    print(out.strip().splitlines()[-1] if out.strip() else "rec: nothing said")


if __name__ == "__main__":
    print(json.dumps(b(sys.argv[1], json.loads(sys.argv[2])))[:4000])


# ---- the pointer on adhd's own screen (cursorless in the recording)
def _post(kind, x, y, button=0):
    import Quartz
    e = Quartz.CGEventCreateMouseEvent(None, kind, (x, y), button)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)


def pos():
    import Quartz
    p = Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))
    return p.x, p.y


def move(x, y, dur=0.6, steps=None):
    import Quartz, math
    x0, y0 = pos()
    n = steps or max(2, int(dur * 60))
    for i in range(1, n + 1):
        t = i / n
        e = 0.5 - 0.5 * math.cos(math.pi * t)
        _post(Quartz.kCGEventMouseMoved, x0 + (x - x0) * e, y0 + (y - y0) * e)
        time.sleep(dur / n)


def click(x=None, y=None):
    import Quartz
    if x is not None: move(x, y)
    px, py = pos()
    _post(Quartz.kCGEventLeftMouseDown, px, py); time.sleep(0.06)
    _post(Quartz.kCGEventLeftMouseUp, px, py)


def drag(x, y, dur=0.8):
    import Quartz, math
    x0, y0 = pos()
    _post(Quartz.kCGEventLeftMouseDown, x0, y0); time.sleep(0.08)
    n = max(2, int(dur * 60))
    for i in range(1, n + 1):
        t = i / n; e = 0.5 - 0.5 * math.cos(math.pi * t)
        _post(Quartz.kCGEventLeftMouseDragged, x0 + (x - x0) * e, y0 + (y - y0) * e); time.sleep(dur / n)
    _post(Quartz.kCGEventLeftMouseUp, x, y)


def key(code, flags=0):
    import Quartz
    for down in (True, False):
        e = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        if flags: Quartz.CGEventSetFlags(e, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, e); time.sleep(0.03)


def clock():
    t0 = time.time()
    def at(s):
        d = s - (time.time() - t0)
        if d > 0: time.sleep(d)
    return at


def later(world, req):
    import threading
    t = threading.Thread(target=lambda: b(world, req), daemon=True); t.start(); return t


def shot(path, rect=None):
    x, y, w, h = rect or main_rect()
    subprocess.run(["screencapture", "-x", "-R%d,%d,%d,%d" % (x, y, w, h), path])


def typing(text, cps=14):
    import Quartz
    for ch in text:
        for down in (True, False):
            e = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
            Quartz.CGEventKeyboardSetUnicodeString(e, len(ch), ch)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
        time.sleep(1 / cps)
