# Dark pages

Built 2026-10-21. When Yab is dark, a site with no dark look of its own is
darkened by Dark Reader's engine built into Yab: dark from the first frame,
one row in Site Controls, ⌥⇧D as in Dark Reader, and sites that have their
own dark theme left alone.

Concept, every state clickable, with the real engine darkening a sample page:
[artifact](https://claude.ai/artifact/9owJ4n2xtprqAdb1reXDG3), also kept here
as [dark-pages/concept.html](dark-pages/concept.html).

Code: `Sources/Fast/DarkPages.swift` (the decision, the lists, the bridge),
`DarkPagesTab.swift` (a tab's part, the View menu, ⌥⇧D, printing),
`DarkPagesSettings.swift` (Settings and the sheet),
`Resources/PageScripts/dark-pages.js` (the page's side),
`Resources/PageScripts/darkreader.js` and `darkreader-proxy.js` (the engine),
`Resources/DarkReader/` (the site lists). Tests: `Tests/FastTests/DarkPagesTests.swift`.
Eval: `evals/dark-pages/run.py`.

## What people see

1. **Theme Dark, a light site:** the page is dark. No toast and no badge: the
   page itself shows it.
2. **Site Controls (⌘E), "This site":** the row "Dark page", symbol moon,
   under "Block ads and trackers". The circle is filled while it is on. It
   shows whenever pages can be dark here, that is while the window is dark
   or the mode is Always. With the mode Off in a dark window it says "Off"
   and turns this one site on (the word "yes" kept for the site, dropped
   again when it is turned off); every other site stays as it was.
   - "On": Yab's engine darkens this site. Pressed: "Off on northwind.news".
   - "The site's own": the site's dark theme is used, the engine is not.
     Pressed: "Off on docs.tiller.dev", and the site keeps following the
     window, so it stays in its own dark theme (#336).
   - "Off on {site}": Yab's engine is off here. The site gets the window's
     `prefers-color-scheme` as with dark pages off: its own dark theme if it
     has one, its light look if not. Pressed: back to Yab's decision.
   - "Dark Reader does it here", with a "Use Yab's" button at the end: the
     extension is on (see below).
3. **⌥⇧D**, the keys Dark Reader uses for "this site", toggles the site in
   front. It is the key monitor's, page first, as every key without ⌘ is: in
   a text field it still types Î. An extension that registered ⌥⇧D keeps it
   (`DarkPages.extensionHolds`). It is never the View menu item's key
   equivalent, which would take Î from every field.
4. **⌘T:** the command "Dark Page", search words "dark night theme invert
   black", symbol moon, ⌥⇧D beside it. Its action says "Turn Off for {site}"
   or "Turn On for {site}" (`Browser.darkPageAction`).
5. **View menu:** "Dark Page" in View › Theme, under System, Light and Dark
   after a separator, checked while the page is dark (by the engine or its own), dimmed where
   pages can't be dark.
6. **Settings › Appearance, third group,** after Page size and Fonts:
   - Row "Dark pages", detail "For sites without a dark look of their own.",
     a menu with "With the theme", "Always", "Off" (the default), and a
     "Customize…" button beside it, as Fonts has.
   - The sheet "Dark Pages", 460 wide like Fonts: a live picture of the page
     in front once the engine has restyled it (a sample page with the real
     engine when the page in front isn't darkened), Brightness (60 to 140%),
     Contrast (60 to 140%), Warmth (Dark Reader's sepia, 0 to 60%), in steps
     of 5, Background (Gray #1c1c1c, Space: the space's hue as dark as Gray,
     Black), "Dim pictures" (photos a little darker, never inverted), and
     "Turned off" (the sites turned off, each with its icon and ×). Restore
     Defaults and Done ↩.
   - `SettingsIndex` item `dark-pages`; agents set the mode through
     `native_apply` (`dark-pages`).
7. **Dark Reader the extension installed and on:** Yab's own stays off, so a
   page is never darkened twice. The Site Controls row says so, and under the
   Settings row a note: "Dark Reader is on in Extensions. Yab leaves dark
   pages to it. Switch to Yab's brings its {n} sites over and turns it off."

Nothing asks the person anything on its own.

## How it works

Two parts: Yab decides what a site gets before the request leaves, and the
page only carries the answer out.

### In Yab

- **`Tab.arm`** (from `decidePolicyFor`, with the address it is going to):
  `darkArm` decides, sets the WebView's appearance, the ground under the page
  (`underPageBackgroundColor`, the stage's ground before the first frame) and
  forgets the light shade remembered for the host (`Tab.forgetShade`), which
  would otherwise light the stage's ground (`StageView.fill`).
  `PageScripts.list` then takes `DarkPages.scripts(for:)`.
- **The lists** (`DarkLists`): `dark-sites.config` (20 KB) read the first
  time a tab arms; `dynamic-theme-fixes.config` (800 KB, 2,900 blocks) on a
  queue of its own as pages can first be dark. Patterns are indexed by the
  first label that isn't `*`, so a URL is matched against a handful of
  blocks. The fixes for a page are the common `*` block with the matching
  block whose first pattern is longest, as Dark Reader's
  `getDynamicThemeFixesFor` merges them.
- **Yab's own fixes,** `yab-fixes.config`, the same format, kept apart so
  `scripts/darkreader-update` never drops them. They add to Dark Reader's:
  its `*` block to the common one, every site block that matches to the
  block Dark Reader's lists pick. Now one: Excel for the web. Its grid canvas
  (`.ewr-sheettable`) has a white ground of its own, which the engine
  darkened, and Dark Reader's fix inverts the canvas: dark inverted came out
  light gray under the words inverted to white (#307). The ground is kept
  white, so the invert makes it dark. Eval: `evals/dark-pages/excel.py`.
- **The bridge** (`DarkRelay`, a `WKScriptMessageHandlerWithReply` in the
  `yab-dark` world only): "ask" (the decision and the frame's fixes, worked
  out off the main thread), "fetch" (`DarkFetch`) and "done" (what the page
  found).

### In the page (every frame)

Three user scripts at document start, the same objects for every site:

- **The proxy**, `darkreader-proxy.js`, in the page's world: Dark Reader's
  `injectProxy`, cut out of the engine by `scripts/darkreader-update`. It
  starts only when the engine sends `__yabdark__proxySC` (its two choices as
  0 or 1). The engine itself would insert it as an inline `<script>`, which a
  strict CSP refuses; `dark-pages.js` catches that one insertion in its own
  world (`Node.prototype.insertBefore` there only) and sends the event
  instead. User scripts are not subject to the page's CSP.
- **The engine**, `darkreader.js` as npm ships it, wrapped in
  `window.__yabDarkEngine = function () { … }` in the `yab-dark` world: every
  frame gets the function, and only a page that needs the engine runs it. In
  its own world the page never sees `window.chrome` or `DarkReader`.
- **The start script**, `dark-pages.js`, one object per look (its theme and
  fallback are in its text). It puts a fallback `<style>` in before the
  parser has drawn anything (dark ground, light words, `color-scheme: dark`,
  as `darkreader--fallback`), then asks Yab and gets the decision and the
  frame's fixes:
  - `engine` / `on`: `DarkReader.enable(theme, fixes)` at once; the engine
    puts its own fallback in, in the same task, and ours goes.
  - `check`: DOMContentLoaded, then the linked stylesheets (each loaded or
    failed, 1.5 s at most). In one task every `darkreader` style and the engine's
    marked `adoptedStyleSheets` overrides are disabled, the ground
    of `<body>`, then `<html>`, then (both transparent) the median of what is
    under three points of the window is read, and the root's `color-scheme`
    with the dark media; the styles are enabled again. Dark: the fallback
    goes, "own". Light: the engine.
  - **The second look,** once the page has loaded (Dark Reader's detector
    waits for that too): where the decision was `check`, or the site's own
    CSS has `prefers-color-scheme: dark` rules, the same look is taken with
    the engine's styles off. Dark: the engine comes off, "own", learned. A
    site whose script puts its dark theme on after the document is parsed
    is caught here (#336).
  - `own` / `off`: the fallback goes.
  - A page with `<meta name="darkreader-lock">` is never darkened.
  It tells Yab "engine" (once loaded and two frames on, with whether the
  site's own CSS has `prefers-color-scheme: dark` rules), "own" or "error".

The fallback is a `<style>` from the start script, not a `_WKUserStyleSheet`,
so it can be taken off one document from inside it. The first-frame films
(below) found no white frame, so the scoped user style sheet the plan kept in
reserve was not needed.

### The decision for a host

`DarkPages.decide`, in order, the first that answers wins:

1. **Mode and window.** Off, or With the theme in a light window: `none`,
   nothing goes into the list. Always in a light window: the WebView gets the
   dark appearance, so a site with its own dark theme uses it.
2. **Not a page for it:** agent tabs (`tab.bench`), headless, anything but
   http and https (Yab's pages, files, PDFs: the start script also leaves any
   document that isn't HTML), and while Dark Reader the extension is on.
3. **The person's word,** `dark.<host>` = `off`. Never learned over. A
   stored `on` (from before #336) counts as no word: a site with a dark
   theme of its own always uses it.
4. **Dark Reader's dark-sites list:** `own`.
5. **What Yab learned:** `darkLearned.<host>` = `engine`, under 14 days old,
   starts the engine at once. A host learned `own` is still looked at each
   time (`check`): a host can have a dark home and a light page under it, and
   trusting `own` left such a page white (the bare page of the first-paint
   eval). The look is one style read; the fallback stays dark meanwhile.
6. **Nothing known:** `check`.

The host is `PageScripts.host(of:)`'s. The main frame's ask decides again
from the address the document really has (a redirect may have moved it).
Frames follow the tab's top site (`DarkPages.frame`): under a darkened or
checking page each frame looks at its own ground (`check`), so a dark player
stays as it is and a white payment form is darkened; under a site with its
own dark look, frames are left alone.

### Turned off

`dark.figma.com = off`: nothing goes into the list, and the tab's WebView
keeps the window's appearance (`DarkPages.appearance`), so the site gets
`prefers-color-scheme` as with dark pages off: in a dark window its own dark
theme, if it has one. The toggle controls Yab's engine only (#336; before,
off meant the light appearance, and a site's own dark theme could not be had).

### Changing it on an open page

⌥⇧D, the row, the command or the menu (`Browser.toggleDarkPage`) sets
`dark.<host>` (`DarkPages.toggle`: from dark, off; from off, the key is
dropped, so the site gets Yab's decision again) and
`DarkPages.refresh(host:)` runs `Tab.darkRefresh` on every tab of the site:

- a page that has the scripts gets `__yabDark.apply(decision)` in each frame
  that asked (`darkTell`): the engine on or off, no reload; a fresh look waits
  80 ms for the appearance change to reach the page's styles;
- a page that came without them (kept light) gets them evaluated into its
  main frame, and they ask as a new document would;
- the WebView's appearance flips, `retone(fresh: true)`, the row's word
  changes, and the next navigation arms with the new decision.

Theme Light ↔ Dark (`NSApp.effectiveAppearance`, watched by
`DarkPages.start`), the mode menu and Dark Reader turned on or off do the same
for every tab. The sheet's controls send the new look to every darkened
frame (`__yabDark.look`), a frame apart.

Reading Mode turns the engine off in its tab while it is up
(`Tab.darkReading`). Printing turns it off for the print sheet and back on
after (`Browser.printSheet`, `PrintEnd`), so paper stays white.

### Learning again

A learned `engine` is looked at again after 14 days, or on the next visit
once the engine finds `prefers-color-scheme: dark` rules in the site's own
CSS that weren't there when it was learned (`DarkPages.relearns`).

### What Yab keeps

| Key | Values | Set by | Kept |
|---|---|---|---|
| `pages.dark` | `withTheme`, `always`, `off` | Settings | Always, synced |
| `pages.darkLook` | brightness, contrast, warmth, ground, dimPictures (JSON) | The sheet | Always, synced |
| `dark.<host>` | `off` (`on` from before #336 is read as no word) | The person | Until changed, synced (`"dark."` in `SyncShapes.settingPrefixes`) |
| `darkLearned.<host>` | `{v: engine or own, at, sign}` | Yab, after the check | 14 days or until a sign, this Mac only |

A private window reads all of these and writes nothing it learns.

## Where it doesn't run, and other cases

- **Agent tabs and headless:** never. An agent sees the page as the site
  sent it.
- **Mail:** keeps its own darkening.
- **Canvases** (Figma, Google Docs, Maps): the engine doesn't repaint a
  canvas's pixels; Dark Reader's fixes cover some of them, the rest can be
  kept light with one press.
- **The engine throws:** everything comes off, fallback and engine, and the
  page stays as the site sent it. The error goes to the log and the debug
  log (`dark.error`) with the host and the lists' version.
- **Dark Reader the extension:** found by its Web Store id
  (`eimadpbcbfnmbkopoojfekhnkhdbieeh`). While it is enabled Yab's own stays
  off. "Switch to Yab's" reads its `disabledFor` sites and its theme from
  WebKit's storage of it (`~/Library/WebKit/<app>/WebExtensions/<profile>/
  eimadpbcbfnmbkopoojfekhnkhdbieeh/{Sync,Local}Storage.db`, table
  `extension_storage`), writes them as `dark.<host> = off` and
  `pages.darkLook`, and disables the extension.

## Security

- The bridge is registered in the `yab-dark` world only. The page's own
  world has no `webkit.messageHandlers.yabDark`, no `DarkReader`, no
  `__yabDark` (a unit test checks).
- Fetches go through an ephemeral URLSession with no cookie storage
  (`credentials: "omit"` in effect): http and https only, at most 2 MB and 10
  seconds, a CSS request refused when the answer isn't text.
- An address on the local network or this Mac is fetched only for a page
  that is itself local (`LocalNetwork.space`). Like local network
  protection, it reads the address as written, not what a name resolves to.
- The page can read the dark CSS the engine writes, as it can with the
  extension. With no cookies sent, nothing private of another site is in it.

## Speed

- The work happens in the page's process, in Dark Reader's frame-sized
  chunks. Yab's main thread only arms, inside `pagescripts.arm`
  (`MainBudget`); the fixes are read and matched off it.
- The three scripts are the same objects for every site while pages can be
  dark, so `PageScripts.fit` sends nothing on a navigation between sites
  (measured below); the list changes only between a kept-light site and the
  rest, and when the look changes.
- The engine is in every frame's list but only parsed there: it runs where a
  page needs it. That settles the plan's open question without a second
  build: own sites and frames left alone never run it.

Measured by `evals/dark-pages/run.py` on one Mac in one process, dark pages
Off and On in turn: see "Proof" below.

## Vendoring and updates

`scripts/darkreader-update VERSION` fetches the npm package, checks its
sha512 against the registry's integrity hash, writes `darkreader.js` as it
ships (its version in its first lines), cuts `injectProxy` out into
`darkreader-proxy.js`, fetches the two lists from the repository at the tag
`vVERSION` into `Resources/DarkReader/` with `VERSION`, and runs the unit
tests on the farm. It stops when the engine no longer has what Yab relies on
(`injectProxy`, `Plugins.fetch`, the proxy's script). `build.sh` copies
`Resources/DarkReader` into the app. The MIT notice is in
`THIRD_PARTY_NOTICES.md` (Acknowledgements.txt). Updated with Yab's
releases, never fetched at run time. Now: Dark Reader 4.9.133.

## Proof

2026-10-22, `evals/dark-pages/run.py` (job.sh) and `evals/dark-first-paint/open.py`
with `DARK_PAGES=withTheme`, farm jobs a5f31b43 (adhd), 666360e3 and
d1bee15a (main). Unit tests: `DarkPagesTests`, 21, the page script with the
real engine in WebKit among them.

**First frames.** Each page opened in a fresh tab in front, filmed through
ScreenCaptureKit, a frame white when every channel of the page's middle is
over 200:

| Page | Before (dark Yab, pages off) | After, first visit | Warm (learned) | Became |
|---|---|---|---|---|
| light only | 190 to 210 white frames | 0 | 0 | engine |
| mixed (dark header and code of its own) | 191 to 221 | 0 | 0 | engine |
| images (img, CSS background, picture, poster, SVG logo) | 196 to 223 | 0 | 0 | engine, no picture inverted |
| canvas | 200 to 230 | 0 | 0 | engine; the canvas itself stays white |
| frames (light, another site's light, dark) | 194 to 215 | 0 | 0 | engine; the light frames dark, the dark one as it was |
| stylesheet 0.9 s late | 111 to 123 | 0 | 0 | engine |
| strict CSP, rules put in by script | 197 to 214 | 0 | 0 | engine, the late rules darkened |
| has its own dark (prefers-color-scheme) | 0 | 0 | 0 | own |
| dark site | 0 | 0 | 0 | own |
| `darkreader-lock` | white | white, as asked | white | left alone |
| example.com, github.com, MDN, docs.python.org | 0 | 0 | 0 | own |
| news.ycombinator.com, en.wikipedia.org | 153 to 216 | 0 | 0 (one run: 1 frame on HN warm, not seen again) | engine |

The first-paint films of #205 with dark pages on: every take 0 white frames
(tab, tab-css, slow-tab, slow-css, back, forward, woken, nav-css, empty-css),
and the bare page with no ground of its own now ends dark (28, 28, 28) with
no white frame. With dark pages off the stage is the same as before (no
script, no appearance or ground set).

**Scroll.** A heavy local page (2,000 cards with gradients, shadows and
pictures) scrolled by script every frame for 4 s, 6 rounds each way in one
process: frame time p50 17 ms both ways, p95 18 ms off and 18 ms on (adhd:
22 and 21.5), p99 about 20 both, frames over 25 ms 0 to 2 in each mode alike.
No cost on scroll.

**Load.** The same heavy page, learned (engine at once), medians: first
contentful paint 103.5 ms off, 137 ms on (adhd: 147.5 and 199);
DOMContentLoaded 15.5 and 19.5 ms; load 90.5 and 110 ms. Starting the engine
only once the document is parsed (`pages.dark.defer`, test runs only) gave
134 ms: the cost is the engine's own work, not when it starts. That is the
price of a dark first frame on a page of 2,000 cards; its first paint is the
fallback's dark, never white.

**Arming.** Ten navigations between sites in one tab: scripts sent anew 0
times off and 0 times on; main-thread arming 1.5 ms off and 2.8 ms on for
the ten.

**Live changes.** Site Controls' row pressed with the panel open: "On" to
"Off on 127.0.0.1", the page light in the same frame series with no reload;
pressed again, dark again.

## Not done yet

- The manual's Dark pages page (fast-web).
- A frame's own dark sites list hit is from its own URL; a frame under a
  kept-light page gets nothing, as its page.
- The 50-site stand eval of the plan (`docs/testing-real-profiles.md`) and
  a side-by-side with Dark Reader the extension on the same sites.
