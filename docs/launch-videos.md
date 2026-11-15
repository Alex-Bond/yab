# Launch videos: three films for the first post

Three films for Yab's first launch post, each its own look and a slightly
different story, all made of Yab itself: frames of the real app taken from
`./demo` worlds (docs/demos.md), composed in Remotion (`videos/launch/`).
Yab draws its own window into a picture (`winshot`), so most frames can be
taken with the screen locked; what a still can't show (motion, a floating
window, an agent's own tab) is a live take, recorded on an unlocked screen
by `videos/launch/live/takes.py` and played inside the same window frame.

| Film | For | Look | Length |
|---|---|---|---|
| **1. Yes, another browser.** | people who miss Arc | the website's paper: dot grid, grain, a pen that writes and points | 36 s |
| **2. Then we gave it hands.** | people who want AI that does things | dark, the window lit from within, slow pushes into the work | 32 s |
| **3. Fast. Like, really fast.** | people who live on the keyboard | white, keys drawn as Yab draws them (KeyArt), one key, one result | 32 s |

All three: 1920×1080 at 30 fps, readable muted (every message is on
screen), a bed from Drift's own synthesizer (`bed.py`, no licensed music),
and the same ending: the mark, the line, "Free for Mac ·
yetanotherbrowser.com". Numbers are measured, never remembered: Yab 0.0.8 is
40 MB on disk once installed, Chrome 1.4 GB installed (measured October 4, 2026, see
[launch/README.md](launch/README.md#one-size-measured)). The site says the
same since October 4.

## 1. Yes, another browser.

One promise: everything Arc had, kept, and done with care.

| # | Frames | Message | Shot |
|---|---|---|---|
| 1 | 0 to 78 | "Yes, another browser.", the pen underlining "another" | the Work space on Paper's launch notes (`f1-work`) |
| 2 | 78 to 150 | "You miss Arc. So we kept all of it." | same |
| 3 | 150 to 282 | Spaces: "a space for each part of you" | Personal, Lisbon, Work (`f1-personal`, `f1-lisbon`, `f1-work`) |
| 4 | 282 to 396 | Peek: "⇧-click any link" | Wikipedia peeked over Hacker News (`f1-peek`) |
| 5 | 396 to 510 | Split View: "any two, side by side" | The Linear Method and Hacker News, one row with two chips (`f1-split`) |
| 6 | 510 to 640 | PiP: "a video, out of its page" | live: the video lifts into its window, then its chapters over Nordbutik (`pip`) |
| 7 | 640 to 770 | The island: "what plays in other tabs" | live: Drift playing, the island rising, then opened (`island`) |
| 8 | 770 to 870 | Clear: "and today's tabs, to dust" | live: today's tabs going to dust (`dust`) |
| 9 | 870 to 972 | "Then we gave it hands." | live: Claude's own tab, filtering for nonstop (`agent`) |
| 10 | 972 to 1080 | ending | mark |

## 2. Then we gave it hands.

One promise: your own Claude or ChatGPT does the work in your tabs, and the
yes stays yours.

| # | Frames | Message | Shot |
|---|---|---|---|
| 1 | 0 to 108 | "Ask for the trip, not the search." | ⌘T with the task typed, Task for Claude first (`f2-ask`) |
| 2 | 108 to 270 | "It works in tabs of its own." / "Clicks, types, reads." | live: Return on Task for Claude, its chat in the column; then its own tab filtering for nonstop (`agent`) |
| 3 | 270 to 426 | "Pay waits for your yes." | Nordbutik's checkout filled (`f2-checkout`), pushing in on the question laid over it (`permit.html`, a copy of the card the real run asked: live take below) |
| 4 | 426 to 570 | "Your mail, sorted by what it wants." | Mail, both mailboxes, Needs you 7 (`f2-mail`) |
| 5 | 570 to 714 | "Replies written ahead, in your voice." | Jonas's thread, reply 1 of 3 ready, Send ⌘↩ (`f2-thread`) |
| 6 | 714 to 846 | "⌘J does what the page is for." | the excalidraw pull request (`f2-page`) |
| 7 | 846 to 966 | "Your Claude or ChatGPT. Your tabs. Your yes." ending | mark |

## 3. Fast. Like, really fast.

One promise: small, and quick to use from the keyboard.

| # | Frames | Message | Shot |
|---|---|---|---|
| 1 | 0 to 84 | Size on disk: Yab 40 MB, Chrome 1.4 GB, bars to scale | type |
| 2 | 84 to 180 | ⌘T: "Everything starts in one field." | `f2-ask` |
| 3 | 180 to 276 | ⌥↩: "A whole form, filled at once." | Lumen's form filled in 34 ms, dots by source (`f3-form`) |
| 4 | 276 to 372 | ⇧⌘2: "Any part of a page, as a picture." | live: the chart's box picked, lifted into the corner (`capture`) |
| 5 | 372 to 468 | ⌥⌘U: "Measure the page you're building." | Measure on Tern's site: the plate with the winning rules and their files (`f3-measure`) |
| 6 | 468 to 564 | ⌥⌘I: "Its errors, beside it." | live: Developer Tools sliding in beside Tern's site (`devtools`) |
| 7 | 564 to 660 | ⇧⌘P: "A video in its own window." | live (`pip`) |
| 8 | 660 to 756 | ⌥⌘L: "Passwords and codes, in your keychain." | Passwords from GitHub's tab, reused and weak tagged (`f3-passwords`) |
| 9 | 756 to 852 | ⌃3: "A space for each part of your life." | the Lisbon space (`f1-lisbon`) |
| 10 | 852 to 972 | ending | mark |

## Live takes

Recorded on adhd, unlocked, with the demo app installed there:
`videos/launch/live/takes.py` builds each scene's world fresh, drives it
through the bench socket and the real pointer and keys, and records the
window with `rec` (ScreenCaptureKit, 60 fps, no cursor, the system's
sound) into `~/yab-takes`; `takes.py --export public/takes` makes the
30 fps clips the films play (`Window` slides with `take` and `from`).

| Take | Scene | In |
|---|---|---|
| `pip`: the video lifting out, playing over Nordbutik, its chapters under the pointer | `pip` | film 1, film 3 |
| `island`: Drift playing, the island rising at the column's foot, then opened | `island` | film 1 |
| `dust`: Clear, today's tabs to dust | `tabs` | film 1 |
| `agent`: a real Claude run, its chat and its own tab | `agent` | films 1 and 2 |
| `capture`: ⇧⌘2, the outline following, the chart lifted off | `capture` | film 3 |
| `devtools`: ⌥⌘I beside Tern's site, errors and network | `devtools` | film 3 |
| `hello`: "Nice to meet you, Mira" written out | `hello` | not used yet |

Still stills, for want of a live take: Pay waits for its yes behind Touch
ID, which a script can't give, so film 2 keeps the checkout with the card
laid over it (`permit.html`); the call in its floating window wants a
camera and someone on the other side.

## Making them

```
cd videos/launch
npm install
python3 bed.py            # the three beds, from Drift's synthesizer
python3 capture.py        # every shot, from ./demo worlds (or f1, f2, f3); the flight shots run Claude
python3 live/takes.py --export public/takes   # on adhd, after live/takes.py
python3 render.py all     # out/board-FilmN.png and out/film-N.mp4
npx remotion studio remotion/index.ts
```
