# Hand-edited site looks

The approved reference is `work/visualizations/boost-editor-motion.html`.
The shared Claude artifact URL returned Page not found during implementation.

There is no brush in the toolbar or the address plate (decided 2026-10-27,
boosts live in Site Controls as in Arc). The card opens over the real page
from Site Controls > Boosts > Add > Customize, which hands over its rectangle
and picture so the card reshapes in place, and from Cmd+T's Customize Site. Commands include Customize Site and explicit
on/off customization actions, with matching context-menu labels and favorite
toggle states. Private tabs and non-HTTP pages do not offer persistent looks.

The hand-edited look is stored in `site-looks.json`, keyed by exact host and
sign-in profile. `www.example.com` is independent from `example.com`.
Scripts check their frozen host again at runtime to exclude redirects.
This file is local to the Mac; this change adds no sync/export contract.
Other boosts, userscripts, and existing Hide Elements rules keep their stores.

## Motion contract

- Card entry/exit: `Motion.arrive` 220 ms / `Motion.depart` 150 ms.
- Site Controls: shell `glide`, old rows `leave`, new rows `morph` with 12 ms steps.
- Direct color drag, Photos, Size, Spacing and CSS typing: no tween.
- Presets/site colors: puck and page use glide 0.34 / 0.82.
- Auto/Light/Dark: selection `glide`; page `reshape` 300 ms. Photos keep their own colors.
- Fonts: selection `glide`, 180 ms text dip, family changes at 70 ms.
- Existing Hide Elements picker keeps its 70 ms hover frame. The editor
  offers Only This/All N; matching elements light with 25 ms steps.
- Hidden items fly into their row on `glide`; the page gap uses `room`
  200 ms. All similar uses 35 ms steps and one grouped row. Show and Cmd-Z
  reverse the path, including the bottom bar's Undo.
- Code resizes the card on `reshape`. Incomplete braces/strings/comments
  retain the last finished CSS. Clearing CSS removes it.
- Ask uses the existing checked boost-trial flow. The fitted CSS is shown
  in the card as arriving lines and highlights matching page elements for
  1.2 s; the trial's existing Keep/Undo controls retain their meaning.
- Holding Option/Original crossfades an inert original rendering over the
  customized page. Hidden items appear as fixed copies, without changing
  the real page's layout or scroll position. The button peeks while the pointer
  is held; keyboard/accessibility activation can toggle it. Pointer and Option
  holds release independently, and leaving the app cancels the preview.
- Reset restores controls on glide and hidden blocks in page order with
  40 ms steps. Reduce Motion removes travel, springs and blur animations.

## Verification

`docs/evidence/boost-editor-motion-2026-10-26/live-webkit.json` records an earlier live
Yab agent-tab check of the shipped JavaScript source, with its SHA-256.
It covers style restoration, inherited typography, photo preservation,
hide/show geometry, Original without reflow, CSS, SPA additions and interrupted
springs/font changes. It is a page-runtime fixture, not native-card acceptance.

The native build, Swift suites and manual motion/interaction review are
registered in `qa/pending/boost-editor-motion.json`, following `qa/README.md`.
Earlier native captures and the seven-test pass are recorded in
`docs/paused-work-2026-10-27.md` (jobs acc90189 and f37c5f76). They predate the
final card changes and are not acceptance of the current source. HTML concepts
are references, not captures of the application.

## Continuation, 2026-10-28

The existing worktree is `/private/tmp/yab-boost-editor-2`, branch
`paused/boost-editor`. The continuation is uncommitted; it has not been copied
over the shared checkout's parallel work, merged, pushed or released.

- Page replies for colors, line height, similar elements and Option-click
  selectors are tied to the exact editor opening. Closing/reopening on the
  same tab rejects a late reply from the previous opening.
- Saved controls are normalized before use and persistence, including legacy
  files without Text Case. Out-of-range font indices cannot index the font
  grid, and nonfinite values cannot poison the saved JSON.
- Original has a momentary pointer gesture and independent Option hold, with
  cleanup on close, cancellation and app deactivation.
- Hidden selectors follow an SPA's replacement node. Original and Show drop
  the detached node's geometry and operate on the current element.
- The existing Add Boost menu tests include Customize. Both toggle states are
  covered in composed field offers, history, web suggestions and Actions.
- The shared QA card captures both themes with `compare.py`, plus the field,
  Site Controls handover and five motion recordings with `screens.py`.
  Failed/incomplete motion recordings fail the probe even if stills exist.
  Capturing files does not record the owner's visual acceptance.

The continuation passed Swift syntax parsing, JavaScript/Python syntax checks,
`git diff --check`, `design-check` and QA card validation. No native compile,
Swift test run or new app capture was submitted for this continuation: ordinary
macOS acceptance belongs to the combined QA batch. Live Ask with a connected
agent and the manual motion/profile scenarios remain explicitly pending there.
