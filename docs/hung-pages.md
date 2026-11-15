# Pages that stop answering

A page can spin in its own script forever: its process alive, its main
thread never free again. Nothing in the window reacts, not a click, not a
scroll, not ⌘R, and from the outside it looks as if Yab itself has died.
This is how Yab finds such a page and gets out of it, whatever tab it is
in. Code: `Sources/Fast/Deaf.swift` (the signal, the card, agent tabs),
`Stuck.swift` (the watchers, `unstick` for reload and stop),
`Tab.letGoDeaf` / `goFresh` (every other way out). Eval:
`evals/hung-pages/check.py` through `scripts/runs/hung_pages_check.sh`, and
`evals/reload-button/check.py` for reload and stop on a hung page.

## The case that started it

2026-10-09, the pinned X tab on main, open on `/home` all day (42 visits).
Its WebContent process (one tab, 1.4 GB footprint) sat at 100% of a core for
over an hour and a half. `sample` showed the main thread inside one call, never
returning: `HTMLMediaElement::dispatchEvent` → a page listener → JIT frames →
`operationStringSplit` / `operationStringStartsWith` / array growth over
rope strings. The window was blank, clicks did nothing.

Ruled out on our side: no Yab script listens to media events on x.com
(YouTube.swift is YouTube only, `retry` in Float.swift adds one `once`
listener, DevMode's console capture runs on local hosts only); the installed
extensions' content scripts listen to none; the shield lists do not touch
X's media hosts; Yab tells sites it is Safari. X's bundles (x-web, about
600 files) were read for the loop: the player store, hls.js and Sentry's
parsers are all bounded, so the exact function was not found. lldb cannot
attach to WebContent, and the inspector connects through the very thread
that is busy. Short repros failed: an agent tab out of sight does not play,
Safari in the background did not hang. It most likely builds up over a long
session of a feed full of videos.

So the bug is X's. Ours is that nothing caught it.

## What Yab did before (2026-10-09)

- **Hidden tabs**: `Stuck.lookForStuck` (Stuck.swift) reads each process's
  CPU; a group of tabs at 25% of a core for 5 minutes that misses two pings
  (`evaluateJavaScript("1")`, 10 s each) is killed (`killContent`) and slept.
  Not judged: the tab on screen, the other half of a split, agent and bench
  tabs, and **a page still loading**. A page holding a draft is left running
  and asked about on return (the `.stuck` PageAsk).
- **The tab in front**: `askFront` pings it every 15 s, but a page whose
  process is busy (≥ 5% CPU) is written down as "working, left". A front tab
  in a loop is never handled.
- **⌘R, the reload button, ⇧⌘R, Back, Forward, typing an address**: all go
  to the hung process as messages it never reads. Nothing happens.
- **Put Tab to Sleep**: asks the page for unsaved work first
  (`unsaved(within: 1.5)`); a hung page doesn't answer and the sleep quietly
  gives up ("not answering"). Disabled on the tab in front anyway.
- **⌘W on a pin or kept tab**: `rest()` tears the view down and the row stays.
  Nothing kills the process; per WebKit's source (WebProcess.cpp, `_exit()`
  from the connection's own queue "in case the main thread is unresponsive")
  the process should end once its last page is closed. Not yet checked on
  macOS 27.
- **"Back to" the pin's home** on an awake pin navigates the hung view: stuck.
- **WebKit's own signal**, `_webViewWebProcessDidBecomeUnresponsive:` and
  `...DidBecomeResponsive:`: not handled anywhere.
- **Killing**: `killContent` (Stuck.swift) asks `_killWebContentProcess`, then
  sends SIGKILL to the pid a second later. Tested 2026-10-01: on macOS 27 the
  private call alone does not end a page in a loop, SIGKILL does.

## How other browsers do it

| | Notices | Asks | Way out |
|---|---|---|---|
| Chrome | an input unanswered 15 s (+1 s ping); a commit after 30 s; visible tabs only | "Page Unresponsive": "You can wait for it to become responsive or exit the page." **Wait** / **Exit Page**, every tab sharing the process listed | SIGTERM, then "Aw, Snap!" with Reload. Closing the tab ends the process (unload handlers get 500 ms) |
| Arc, Dia | Chromium's signal, their own `ArcHungRendererDialog` (crash / wait) | Chromium's words, look unconfirmed | Arc: "Tab crashed. Maybe reload the page?" |
| Safari | WebKit's responsiveness timer, 3 s after an input or a load | nothing on its own; only when you stop, reload, go back or visit: "The webpage is not responding, so loading cannot be stopped. Do you want to force reload this page?" naming other pages that must reload with it | **Force Reload** ("might lose information you've entered"); after a crash it reloads by itself with a banner |
| Firefox | a script over 10 s while you interact | a bar: "This page is slowing down Firefox." **Stop** | stops the script, not the process |

Every one of them waits for you to touch the page before saying anything,
and none reloads on its own after you chose to end a page. Sources and
exact strings: the research notes of 2026-10-09 (Chromium
`components/input/input_constants.h`, WebKit `ResponsivenessTimer`,
`WebProcess.cpp`, Safari 27 string tables).

## How it works now

One rule above the rest: **every way out works on a hung page.** Reload,
close, going home, sleeping, typing an address: if the page is not answering,
the action ends its process first and then does what was asked, on a fresh
one. The card is only for when you haven't asked for anything yet.

### Knowing a page is hung

A tab is *not answering* (`Tab.deaf`, since when) when either:

1. WebKit says so: `_webViewWebProcessDidBecomeUnresponsive:` (3 s after an
   input or a load went unanswered), for any tab, the split's other half
   included. Cleared by `...DidBecomeResponsive:`, by its process ending, and
   by its view going.
2. The pings in front say so: two missed while its process spins
   (`judgeFront`, which used to write "working, left"). Known deaf, nothing
   is asked yet, since nobody reached for it, but every way out below acts on
   it at once.

### The card

Shown on a tab on screen (either half of a split) once it is not answering
**and you have tried to use it**: WebKit's word comes 3 s after the click or
key, and the card 12 s after that (`stuck.deafAsk`), **15 s** in all. Reaching
for a page already known deaf (`PageView.reached`: a click, a key, the start
of a scroll) asks once that grace has elapsed. A page that is only busy while
you read something else stays
quiet, as in every other browser. The grace period lets finite main-thread
work, such as opening an image preview, finish without an interruption
(feedback #1139, register 1570). `evals/golden/busy_page_recovery.py` checks
an eight-second preview, repeated input during it, and sustained hangs.

It is the existing `.stuck` PageAsk, centered on the page, nothing dimmed:

- Title: **This page stopped answering** (as today).
- Body, only when there is something to say:
  - a draft in it: "It holds something you typed and didn't send.
    Reloading loses it." (as today)
  - other tabs in the same process: "Reloading also reloads “X Home”."
    (several: "…and 2 other tabs.")
- **Wait** (esc) and **Reload** (⌘R, the key a frozen page is pressed with
  anyway; not Return, which could reload a page holding unsent text by
  accident).

**Wait** closes the card and leaves the page alone; reaching for it again
asks again only after 30 s (`Tab.deafQuiet`). Leaving the tab takes the card
down; coming back and clicking asks again. If the page answers by
itself, the card goes away with no word said.

**Reload** ends the process (`killContent`, marked in `stuck.ending` so it is
not counted as a crash) and loads the same address on a new one at once. No
"page crashed" screen: you asked for it.

### Each way out

| You do | Page answering | Page not answering |
|---|---|---|
| ⌘R, reload button | reload | end the process, load the same address (`unstick`: at once when known deaf, else after 2 s unanswered) |
| ⇧⌘R | as today | end, clear the site's caches, load |
| ⌘. Stop, the cross | stop | end the process, the page stays stopped saying "This page stopped responding" (`unstick`) |
| ⌘W, any tab | close | close, its process ended first (`letGoDeaf`: SIGKILL by pid) |
| ⌘W on a pin or kept tab | put down, row stays | the same: put down with its process ended. Next click opens it fresh |
| "Back to" home, ⌘T Reset Tab | go home | end, then open home on a new view |
| Address typed, Back, Forward | go | end, then go |
| Put Tab to Sleep (a tab behind) | as before | end and sleep; a draft it said it held still keeps it awake |

A pin that has hung is therefore always one ⌘W away from fresh: the pin stays
where it is, its page is gone, and clicking it opens its home.

### Tabs out of sight

The watcher stays as it was, with one change: a page **still loading** is
judged too once it is known deaf; before, a page that hung while loading was
never put down. Pins and kept tabs were already judged.

### Agent tabs

An agent's tab out of sight that stops answering mid-task is ended and
reloaded after **20 s** (`stuck.deafAgent`) without asking, and the agent is
told with its next look (`StuckWatch.notices`): "The page stopped answering
and was reloaded." On screen, it is any tab's: the card.

### Tabs sharing a process

Pages opened by another's script share its process, and the loop holds
them all, so ending one ends them all. The card names the others; reloading
reloads them too (the one in front at once, the rest on return, as after any
crash).

### What is written down

Each step in the Watchdog log: a page found deaf and by whom, asked, ended,
answering again. A `sample` of the stuck main thread in crash reports is not
built yet; it would have named X's loop.
