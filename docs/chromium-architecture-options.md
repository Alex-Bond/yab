# What makes Yab's Chromium fast

Spike of 2026-10-31 on branch `claude/chromium-arch`. Gains are
measured unless the row says reasoned or by the timeline, with `scripts/cef/ab.py` on a signed app with the official SDK
`official-26ac72e8e071`, no CEF patch. Numbers are compared only within one Mac.
Raw rounds are in `docs/evidence/chromium-arch-2026-10/`.

## The answer

Neither the helper process, nor the window per tab, nor the DevTools agents are
what separates Yab from Chrome. Measured with the helper fixes of
`claude/chromium-parity` underneath:

| Gap to Chrome | Where it is | What closes it |
| --- | --- | --- |
| Tab switch, 34 vs 12.6 ms on m4 | 20 ms pass in Swift before the helper hears of the switch. The helper to the page's frame takes 12 ms, the same in one window as in sixty | Tell the helper first, from the pick, off the main thread (spike 2): 10.1 ms |
| Launch plus first page, 1.47 vs 1.22 s on m4 | Helper 0.2 s, agent and 22 scripts 0.15 s, page 60 ms slower. The 3.8 s is gone on the parity branch | Trimming, not architecture |
| 60 tabs, 1.3 GB | Renderers +702 MB, not caused by agents (the memory branch's V8 variant takes 500 MB). Yab's own Swift app +246. Helper over Chrome's browser process +254, GPU +96 | Memory branch first, then (b) for about 270 MB if it is worth it |
| Idle CPU, 60 tabs | On a 20 s window after load, 8.6 vs 3.7, mostly renderers and noisy. 80 s after load, about 1 point: renderers 9 to 16 points in both, the helper 1.4 against Chrome's 0.6 | Parity's fix, nothing here |

## Ranked options

| Rank | Option | Gain, measured | Days | Risk | CEF patch |
| --- | --- | --- | --- | --- | --- |
| 1 | (e) Show ahead: `tab.visible` from the pick, off the main thread | Switch 34.0 to 10.1 ms, Chrome 12.6 (m4, 4 rounds). 33.2 to 12.4, Chrome 10.6 (renderer-2, 3 rounds) | 1 | Low: one idempotent message | No |
| 2 | (b) One Chrome window, tabs in its strip | Memory -266 MB of 9.6 GB at 60 tabs (helper -154, GPU -128). Switch 0 ms. New tab 24 to 16 ms. Idle no better (helper 2.9 against 1.4 points, partly the spike's polling) | 10 to 15 | High: split, spaces, every external-page patch | Yes, 2 SDK builds |
| 3 | (d) No DevTools agent on tabs | None found: in Chrome, agents on 60 tabs change memory by -176 MB and idle CPU by +0.7 points, inside the noise | 10+ | High: isolated worlds and bindings have no CEF API | Probably |
| 4 | (a) Helper started at app launch | 0 to 0.05 s, inside the noise: launch plus first page 1.47 s to 1.48 s alone, 1.42 s with show ahead (m4, 4 rounds) | 1 | Low | No |
| 5 | (a') Warm process from login | At most 0.5 s, by the timeline, for one launch a day. Not built | 3 | Costs the helper's 550 MB with a tab, always | No |
| 6 | (c) CEF inside the Yab process | Socket trip 0.3 ms, so under 1 ms a switch | 30+ | Severe: a CEF CHECK kills Yab, Swift stalls stall Chromium's UI thread | No |

## Option by option

### (e) What Chrome's switch does, and what we repeat

`Target.activateTarget` in Chrome reaches `TabStripModel::ActivateTabAt`, then
`BrowserView::OnActiveTabChanged`: `SetWebContents(nullptr)`, then the new
contents, whose `WasShown` goes to the renderer. The window's compositor never
stops. The page fires `visibilitychange`, then two `requestAnimationFrame`s. That
second frame is the stand's mark: 15 ms on m4. Two frames at 60 Hz cannot take
less than the wait for the next vsync, so part of that is the display, not work.

Yab today, medians on m4, three rounds of 30 switches each:

| Step | Base, ms after the pick | One window |
| --- | --- | --- |
| Swift: `Browser.select`, SwiftUI's pass, then `syncGeometry`'s Task | 20.2 | 20.8 |
| Socket to the helper | 0.2 | 0.2 |
| Helper to the page's second frame | 12.3 | 11.4 |
| Total | 32.6 | 32.5 |

Base hides a window and shows another: `widget_->Show()` wakes that window's
`ui::Compositor`, which is the expensive-looking path. The measurement says it
is not: the two rows agree to a millisecond. We skip nothing and repeat nothing in
Chromium. We start 20 ms late, because `tab.visible` waits for the page's view to
join the stage, and the view waits for Swift's redraw of the window.

**Spike 2** (`YAB_CEF_SHOW_AHEAD=1`, `ChromiumPage.showAhead`) sends `tab.visible`
from `Browser.select` before the redraw, in a detached task, so it reaches the
client actor while the main thread is busy.

| Round medians, 30 switches each, ms | m4 | renderer-2 |
| --- | --- | --- |
| Base | 35.0, 34.7, 31.1, 35.7 | 32.0, 37.8, 29.9 |
| Show ahead (on m4 with eager start on too, which does not touch a switch) | 8.8, 12.9, 9.3, 10.7 | 12.6, 12.8, 11.8 |
| Chrome 156 | 9.4, 13.6, 13.2, 13.2 | 11.3, 10.9, 9.6 |

What this does not prove: the stand's mark is the page's own frame, not pixels on
the display. A page frame is seen once Yab commits its stage, 20 ms after the pick
on m4 (`switch Yab commit ms`, unchanged by the spike). Before the spike the frame
came 14 ms after that commit; now it is ready before it, so the screen should gain
those 14 ms, which is arithmetic, not a measurement of the display. Chrome has no
such commit, so Yab's 20 ms is the next thing to cut: the redraw deferral WebKit
pages already have (`Narrow.deferSwitch`) does not apply to Chromium pages. That is
Swift work, no engine work.

### (a) Keeping the helper warm

The 3.8 s of the brief does not exist on the parity branch: first page is 0.99 s
on m4. It was not broken down on the old build, so what it was made of is not
measured here; what is left is this, from the first page being asked for, m4:

| Step | ms |
| --- | --- |
| Helper process to `main` | 30 |
| `CefInitialize` and context | 130 to 170 |
| Hello | 20 |
| Profile | 40 to 90 |
| Native tab | 60 to 90 |
| Agent's first document, 22 page scripts | 150 |
| Cookies | 50 |
| The page itself | 270 |

Under load (a farm job beside it) `CefInitialize` reaches 420 ms; nothing else moves
much. Most of the helper is not the 3.8 s: it is up in 200 ms.

The fair comparison is launch plus first page, because the stand's "first page"
starts after Chrome has launched too. Excluding each run's first launch after a new
copy of the app, when macOS takes 3 s or more over it, m4 gives Yab 1.47 s and
Chrome 1.22 s.

**Spike 3** (`YAB_CEF_EAGER=1`) starts the helper in
`applicationWillFinishLaunching`. The helper's context comes up 100 ms sooner, then
waits: Swift's hello runs on the main thread, which is building the window. First
page 0.98 s against 0.99 s, launch plus first page 1.48 s against 1.47 s: no gain
above the noise. The time before `willFinishLaunching` is dyld loading Yab, out of reach
from inside. Not worth a code path.

A warm process from login is what is left, and the timeline caps it at about 0.5 s
(everything up to `navigate`), for one launch a day, at the cost of a helper with
a spare tab resident all day on every Mac. Rejected without building it. A warm
renderer is already what parity's spare page does.

The stand's old "launch" also counted `codesign --verify --deep` of the whole
bundle. Fixed here.

### (b) One Chrome window hosting all tabs

**Spike 1** (`YAB_CEF_ONE_WINDOW=1`, `YabCore/src/one_window.inc`). Worked first
time on the shipping SDK: a normal Chrome `Browser`, concealed, tabs added with
`Target.createTarget`, shown with `Page.bringToFront`, which is
`TabStripModel::ActivateTabAt`, the path Chrome's own switch takes. Yab hosts the
window's one compositor.

| m4, 3 rounds, 60 tabs | Base | One window | Chrome |
| --- | --- | --- | --- |
| Switch p50, ms | 33.0 | 32.5 | 15.0 |
| Total MB | 9594 | 9328 | 8312 |
| Helper or Chrome browser process, MB | 523 | 369 | 269 |
| GPU process, MB | 220 | 92 | 124 |
| Renderers, MB | 8532 | 8526 | 7830 |
| Yab's Swift app, MB | 246 | 246 | |
| New tab in the helper, median of 50, ms | 24 | 16 | |

The same question asked of Chrome alone, with no Yab code: Chrome with one popup
window per tab costs 438 MB more than Chrome with tabs (browser +184, GPU +316,
renderers inside their usual spread). A window per tab costs 5 to 7 MB a tab,
whoever does it, and that is the whole prize of (b).

Against that gain, the design forces real work. Chrome's strip holds one profile,
and every Yab space is a profile, so a space switch stays a window switch. One
compositor shows one page, so split view and multiple Yab windows need several
Browsers and tab moves between them. `ExternalPage::Owns()` assumes one tab in a
window, and the native hooks go through it. Spike limits: all spaces share the Default
profile (`Target.createTarget` only reaches it), popups are refused, the window is
ordered in with alpha 0 instead of externally hosted.

Worth doing only once the memory branch has finished and 282 MB is the biggest
thing left. It would also retire patches 0019, 0020, 0028 and 0050, which fake a
tab strip for extensions: that is its best argument, not speed.

### (d) DevTools agents

Priced in Chrome itself, so nothing else differs. `chrome` has a plain session per
tab; each other row adds one piece of what `scripts.inc` sets up. 60 tabs, 40 s
settled, 40 s measured, 3 rounds:

| World | Total MB | Idle CPU % |
| --- | --- | --- |
| Chrome | 8328 | 9.3 |
| + `Page.enable` | 8199 | 11.0 |
| + `Runtime.enable` | 8287 | 8.3 |
| + `Target.setAutoAttach` | 8257 | 9.4 |
| + 14 scripts of 40 KB | 8137 | 9.0 |
| All of it | 8152 | 10.0 |
| All, then turned off after load | 8191 | 10.9 |

All inside the noise of one row (renderers vary 7 to 10 points across rounds).
An earlier 20 s window suggested +2.8 points from agents; the longer one does not
repeat it. Yab's real set is 22 scripts, 344 KB, 9 of them in every frame.

There is one non-speed cost: `PageLiveStateDecoratorHelper` marks a page with an
attached agent as DevTools-open, and `kDevToolsOpen` makes it ineligible for
Chrome's own discard policy. Yab sleeps tabs itself, so this does not bite today.

Replacing the agents is also hard. `OnContextCreated` fires for every world but
names none and cannot make one, and 19 of the 22 scripts run in named isolated
worlds. Only CDP or an extension's content scripts create those, and Yab has no
way to load its own component extension in a Chrome-style profile without a patch.

### (c) CEF in-process

Reasoned, with one measured input: the socket costs 0.3 ms a trip with parity's
wake-up. The helper to Yab boundary is free. Moving CEF inside would hand Chromium's
UI thread to Yab's main thread, the one that just spent 20 ms in SwiftUI on a
switch; a browser-process CHECK would end Yab with its mail and column instead of
one recoverable helper. `CefInitialize` still costs the same. No gain to buy.

### Idle CPU at 60 tabs

`--idle-only`, m4, 40 s settled, 40 s measured, three rounds, points of one core:

| Process | Base | One window | Chrome |
| --- | --- | --- | --- |
| Renderers | 12.4, 12.4, 9.0 | 12.3, 10.2, outlier | 16.2, 8.9, 9.0 |
| Helper or Chrome browser process | 1.4 | 2.9 | 0.6 |
| Yab's Swift app | 0.3 | 0.2 | |
| GPU | 0.0 | 0.1 | 0.1 |

Renderers decide this figure, in Chrome as much as in Yab, and they vary more
from round to round than any architecture moves them. One one-window round was
still settling (66%) and is left out. Two base rounds came up with 73 renderers
and about 1 GB less, against 63 in every other run. That looks like tabs still
unloaded at the measurement, not a saving: memory figures here come from the
engine run above, where all three rounds had 63. Not investigated further.

## Recommendation

1. Land show ahead: 20 ms of a switch for one message.
2. Defer Yab's own redraw for Chromium pages, as for WebKit. That is the next 20 ms.
3. Keep the helper, the window per tab and the agents. None of them is what is slow.
4. Revisit (b) after the memory branch, for its 270 MB and for retiring the patches
   that fake a tab strip for extensions, not for speed.

No CEF patch and no SDK build is needed for 1 and 2. The spike flags
`YAB_CEF_ONE_WINDOW` and `YAB_CEF_EAGER` should not land.

Show ahead's real-profile check is still owed: it ran on the stand's fixture only,
12 local pages, no extensions, on the bench's `select`, not on a click.
