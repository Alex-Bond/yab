#!/usr/bin/env python3
"""The films' frames: Yab itself, in Mira's demo worlds (docs/demos.md),
each state staged through the bench and drawn by Yab into a PNG (winshot
renders the window in-process, so this works with the screen locked).

    python3 capture.py              every shot into public/shots, and remotion/shots.json
    python3 capture.py f2-folder    one shot (a prefix: f2 for all of film 2)

Shots that need a real agent run Claude Code on your plan (a few minutes).
"""
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DEMOS = REPO / "demos"
sys.path.insert(0, str(DEMOS))
import persona as P  # noqa: E402
import world as Wd  # noqa: E402
from scenes import SCENES  # noqa: E402

SHOTS = HERE / "public" / "shots"
MANIFEST = HERE / "remotion" / "shots.json"


def bench(world, request, timeout=60):
    return Wd.bench(world, request, timeout=timeout)


def front_id(world):
    return next(t["id"] for t in bench(world, {"do": "tabs"})["tabs"] if t["active"])


def tab_id(world, piece):
    return next((t["id"] for t in bench(world, {"do": "tabs"})["tabs"] if piece in t["url"]), None)


def open_world(name, scene, settle=6):
    """A world for the films: the scene's, with the window at the size the
    films frame (1440x900, parked past the screen's edge)."""
    world = "film-" + name
    Wd.build(world, scene, background=True)
    time.sleep(settle)
    return world


def snap(world, name):
    path = SHOTS / (name + ".png")
    bench(world, {"do": "winshot", "path": str(path)}, timeout=90)
    print("  shot", name)
    return name


def scene(name, **change):
    made = dict(SCENES[name])
    made.update(change)
    return made


def wait_page(world, tab=None, seconds=12):
    bench(world, {"do": "wait", "id": tab or front_id(world), "seconds": seconds}, timeout=seconds + 10)
    time.sleep(1.5)


def run_task(world, prompt, until=("done", "failed", "stopped"), seconds=420, shots=None):
    """A real task on Claude; `shots` maps a moment ("folder", "dock") to a callback."""
    session = bench(world, {"do": "agent-run", "prompt": prompt, "cli": "claude", "model": "sonnet"})["session"]
    began = time.time()
    state = {}
    while time.time() - began < seconds:
        state = bench(world, {"do": "agent-wait", "session": session, "seconds": 0})
        if shots:
            shots(state, session)
        if state.get("state") in until or (shots and getattr(shots, "done", lambda: False)()):
            break
        time.sleep(4)
    return session, state


# ---------------------------------------------------------------- film 1

CLEAN_NOTES = """(function(){var p=[...document.querySelectorAll('p')].find(p=>/basically a way/.test(p.textContent));
if(p)p.textContent="Focus-first scheduling protects focus time before anyone can book a meeting. When a teammate looks for a time with you, "+
"the slots that would break up your longest blocks of focus aren't shown at all. It's the thing our users have asked for most.";return !!p})()"""

def film1():
    w = open_world("work", scene("all", front={P.WORK: "paper.localtest.me/d/launch-notes"}))
    wait_page(w)
    # The rambling paragraph is there for Improve Writing (the commands
    # scene); the film opens on the notes as they read after it.
    bench(w, {"do": "eval", "id": front_id(w), "js": CLEAN_NOTES})
    time.sleep(1)
    snap(w, "f1-work")
    hn = tab_id(w, "news.ycombinator.com")
    bench(w, {"do": "select", "id": hn})
    wait_page(w, hn)
    bench(w, {"do": "peek", "url": "https://en.wikipedia.org/wiki/Web_browser", "from": "a.titleline > a, .titleline a"})
    time.sleep(4)
    snap(w, "f1-peek")
    bench(w, {"do": "peek", "act": "close"})
    Wd.quit_world(w)

    w = open_world("personal", scene("all", space=P.PERSONAL, front={P.PERSONAL: "nordbutik.localtest.me/p/"}))
    wait_page(w)
    snap(w, "f1-personal")
    video = tab_id(w, "aircAruvnKk")
    bench(w, {"do": "select", "id": video})
    wait_page(w, video, 15)
    snap(w, "f1-pip")
    Wd.quit_world(w)

    w = open_world("lisbon", scene("all", space=P.LISBON, front={P.LISBON: "google.com/travel/flights"}))
    wait_page(w, seconds=15)
    snap(w, "f1-lisbon")
    Wd.quit_world(w)

    # Split View: two sites people know, as one tab, written as a pair.
    w = open_world("split", scene("all", front={P.WORK: "linear.app/method"}))
    method, hn = tab_id(w, "linear.app/method"), tab_id(w, "news.ycombinator.com")
    bench(w, {"do": "select", "id": method})
    wait_page(w, method, 15)
    bench(w, {"do": "pace", "action": "split-enter", "id": hn, "seconds": 1.5}, timeout=60)
    time.sleep(8)
    snap(w, "f1-split")
    Wd.quit_world(w)

    w = open_world("island", scene("island", after=[]))
    wait_page(w)
    time.sleep(2)
    bench(w, {"do": "band", "action": "pretend:2"})
    time.sleep(1.5)
    bench(w, {"do": "band", "action": "open", "seconds": 1.2})
    snap(w, "f1-island")
    Wd.quit_world(w)


# ---------------------------------------------------------------- film 2

def film2():
    w = open_world("agent", scene("agent"))
    go, back = P.trip(time.time())
    wait_page(w, seconds=15)
    bench(w, {"do": "box", "act": "t"})
    time.sleep(1)
    words = "find the best direct flight to Lisbon on my dates, I want a window seat"
    bench(w, {"do": "box", "act": "type", "text": words})
    time.sleep(2)
    snap(w, "f2-ask")
    bench(w, {"do": "box", "act": "key", "keys": "escape"})
    taken = set()

    def agent_tabs():
        return [t for t in bench(w, {"do": "tabs"})["tabs"] if t.get("agent")]

    def moments(state, session):
        tabs = agent_tabs()
        if "folder" not in taken and tabs and time.time() - moments.began > 12:
            taken.add("folder")
            snap(w, "f2-folder")
        page = next((t for t in tabs if "google.com/travel" in t["url"]), None)
        if "dock" not in taken and page and time.time() - moments.began > 40:
            taken.add("dock")
            bench(w, {"do": "select", "id": page["id"]})
            wait_page(w, page["id"], 10)
            time.sleep(3)
            snap(w, "f2-dock")
    moments.began = time.time()

    prompt = ("Find the best direct flight from Stockholm Arlanda to Lisbon leaving %s and returning %s for one adult, "
              "with a window seat if the site shows seats. Compare two or three options and tell me which to book." % (go, back))
    session, state = run_task(w, prompt, shots=moments)
    print("  flights:", state.get("state"), (state.get("result") or "")[:160].replace("\n", " "))
    answer = next((t["id"] for t in bench(w, {"do": "tabs"})["tabs"] if t["url"].startswith("yab://task")), None)
    if answer:
        bench(w, {"do": "select", "id": answer})
        time.sleep(3)
        snap(w, "f2-answer")
    Wd.quit_world(w)

    # Pay waits for a yes. Filling a card asks for Touch ID, which a locked
    # screen can't give, so the film shows Nordbutik's checkout filled as
    # Yab fills it, with Yab's question laid over it (permit.html, a copy of
    # the card the real run asked: "Place your order · 1 249 kr?").
    w = open_world("checkout", scene("checkout"))
    tid = front_id(w)
    bench(w, {"do": "go", "id": tid, "url": "http://nordbutik.localtest.me:8800/checkout?bag=fjord-linen-throw:sand:1"})
    wait_page(w, tid, 12)
    bench(w, {"do": "forms", "act": "fill"}, timeout=60)
    card = ("(function(){var set=(n,v)=>{var e=document.querySelector('[name='+n+']');if(!e)return;e.value=v;"
            "e.dispatchEvent(new Event('input',{bubbles:true}));};set('cardnumber','4242 4242 4242 4242');set('exp','09 / 29');"
            "set('cvc','424');set('ccname','Mira Lindqvist');var b=[...document.querySelectorAll('button')]"
            ".find(b=>/^Pay/.test(b.textContent.trim()));if(b)b.scrollIntoView({block:'center'});return 1})()")
    bench(w, {"do": "eval", "id": tid, "js": card})
    time.sleep(2)
    snap(w, "f2-checkout")
    Wd.quit_world(w)
    permit_card()

    w = open_world("mail", scene("mail"))
    time.sleep(6)
    bench(w, {"do": "agent-mail-space", "act": "enter"})
    time.sleep(3)
    snap(w, "f2-mail")
    bench(w, {"do": "agent-mail-space", "act": "open", "value": P.MIRA["work_email"] + "|jonas-ship"})
    time.sleep(8)  # the replies written ahead
    snap(w, "f2-thread")
    Wd.quit_world(w)

    w = open_world("review", scene("agent", space=P.WORK, front={P.WORK: "github.com/excalidraw"}))
    wait_page(w, seconds=15)
    bench(w, {"do": "ui", "task": "line"})
    time.sleep(2)
    snap(w, "f2-page")
    Wd.quit_world(w)


# ---------------------------------------------------------------- film 3

def film3():
    w = open_world("rows", scene("morning"))
    wait_page(w)
    bench(w, {"do": "box", "act": "t"})
    time.sleep(6)
    bench(w, {"do": "agent-hints"})
    time.sleep(2)
    snap(w, "f3-rows")
    bench(w, {"do": "box", "act": "key", "keys": "escape"})
    Wd.quit_world(w)

    w = open_world("form", scene("forms"))
    wait_page(w)
    fill = bench(w, {"do": "forms", "act": "fill"}, timeout=60)
    print("  form filled in %s ms" % fill.get("ms"))
    time.sleep(2)
    snap(w, "f3-form")
    (SHOTS / "f3-form.json").write_text(json.dumps(fill))
    Wd.quit_world(w)

    # Measure on Tern's site in the making: the hero's button picked.
    w = open_world("measure", scene("measure"))
    tid = front_id(w)
    wait_page(w, tid, 15)
    bench(w, {"do": "ui", "measure": True})
    time.sleep(2)
    spot = bench(w, {"do": "eval", "id": tid, "js": "(function(){var b=document.querySelector('.hero .button--primary');"
                     "var r=b.getBoundingClientRect();return [r.left+r.width/2, r.top+r.height/2]})()"}).get("value") or [500, 400]
    for act in ("hover", "click"):
        bench(w, {"do": "eval", "id": tid, "world": "yab",
                  "js": "window.__yabMeasure && window.__yabMeasure.bench({act:'%s', x:%d, y:%d}), 1" % (act, spot[0], spot[1])})
        time.sleep(1)
    time.sleep(2)
    snap(w, "f3-measure")
    Wd.quit_world(w)

    w = open_world("devtools", scene("devtools", prefs={"dev.side": "right"}))
    wait_page(w)
    bench(w, {"do": "ui", "devtools": True})
    time.sleep(4)
    bench(w, {"do": "ui", "devpane": "errors"})
    time.sleep(5)
    snap(w, "f3-devtools")
    Wd.quit_world(w)

    # Passwords from GitHub's tab: the account kept for it and its live 2FA code first.
    w = open_world("passwords", scene("agent", space=P.WORK, front={P.WORK: "github.com/excalidraw"}))
    wait_page(w, seconds=15)
    bench(w, {"do": "ui", "passwords": True})
    time.sleep(3)
    snap(w, "f3-passwords")
    Wd.quit_world(w)


def permit_card():
    import files
    subprocess.run([files.chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000",
                    "--user-data-dir=" + str(HERE / "out" / "chrome"), "--window-size=1160,180",
                    "--screenshot=" + str(SHOTS / "permit-pay.png"), (HERE / "permit.html").as_uri()], capture_output=True, timeout=60)
    print("  shot permit-pay")


def manifest():
    names = {p.stem: p.name for p in sorted(SHOTS.glob("f[123]-*.png"))}
    # One picture serves where two films show the same thing.
    for alias, source in {"f3-pip": "f1-pip"}.items():
        if alias not in names and source in names:
            names[alias] = names[source]
    MANIFEST.write_text(json.dumps(names, indent=1))
    print("%d shots in %s" % (len(names), MANIFEST))


def main():
    SHOTS.mkdir(parents=True, exist_ok=True)
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    for film in (film1, film2, film3):
        if not only or film.__name__.startswith(only[:2].replace("f", "film")):
            try:
                film()
            except Exception as error:  # a film's shots shouldn't stop the others'
                print("  %s stopped: %s" % (film.__name__, error))
    manifest()


if __name__ == "__main__":
    main()
