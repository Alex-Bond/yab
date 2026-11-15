# Yab's own features on a Chromium tab

What Yab adds to a page, and how each reaches a tab whose page lives in the
helper. [chromium-webkit-only.md](chromium-webkit-only.md) keeps the inventory of
labels; this page says what is true of the features. The eval is
`evals/chromium-features/` (`job.sh APP --areas …`, `addons.sh`, `contracts.sh`).

## Navigation policy

A WebKit tab asks `Browser.page(_:decide:)` before every main-frame load, and
most of what makes a link Yab's lives there: a pinned tab's preview, a site's
space, an assistant's allowed sites, the phishing list, the Keep card for a
`.user.js`, Gmail's addresses, and arming the next document's scripts.

CEF's `OnBeforeBrowse` can't wait, so a Chromium tab's question is asked from
`OnBeforeResourceLoad`, the one callback that can hold a request
(`RV_CONTINUE_ASYNC`, `YabCore/src/shield.inc`). The helper sends `page.action`
with the address, method, transition and gesture; `ChromiumPage+Policy.swift`
builds the same `PageAction` and replies `page.actionReply`. Redirects ask again.
A client that says nothing for ten seconds is taken as a yes. Frames are not
asked. Only documents that go through the network stack are: `about:` and `data:`
never reach it.

A held navigation must not wait on DevTools: it keeps back what it is sent while a
page is on its way to a renderer, so a command waiting for its answer waits for the
navigation being held. Replying after the page's whole command queue cost a page
opened in the spare 10 to 15 s with an appearance command behind it. The reply goes
at once unless the decision armed scripts, and then within 120 ms. What is late
reaches the agent as the document starts, and Shield's stylesheets, registered with
`runImmediately`, take effect in the document that has just arrived.

⇧-click and ⌥-click on a link never reach the page: Chrome would open a window
and save the file. `takesModifiedLink` takes the press when the hover status names
a link, and the release goes through the same policy with its flags.

## Shield

`Filters` is the one converter. Each build also writes
`Shield/chromium.rules` (`ShieldRules.swift`), the url-filters read back into the
shape the lists wrote them, and `shield.configure` tells the helper the file and
the switches (`ShieldChromium.swift`, from `Shield.apply`).

`YabCore/src/shield_engine.h` is plain C++ with its own test
(`YabCore/tests/shield_engine_test.cc`, and `evals/chromium-features/shield_diff.py`,
which compares it with the lists' regular expressions over real lists). A rule
sits in the bucket of its rarest token, as uBlock Origin and adblock-rust do.
Every request goes through `CefResourceRequestHandler::OnBeforeResourceLoad`;
service and shared workers through the profile's `CefRequestContextHandler`.

Hiding is a constructed stylesheet in a world of its own, adopted by the top
document, so the page's DOM holds nothing of it. The thirteen thousand rules for
every site that are a plain class or id stay out of it: a mutation observer looks
for them among the page's elements as the parser adds them, before they are
painted, and only what the page has goes in (uBlock Origin's low-generic filters).
A site's own rules are chosen in `OnBeforeBrowse`, before the request, for
navigations no client asked for too.

Limits: frames get no hiding rules, WebSockets are not seen by this callback, and
a chosen ad blocker extension runs beside Shield rather than instead of it (its
`Blockers` hand-over is WebKit's rule lists). WebKit's quiet sites have no
counterpart: a look costs microseconds here, not a list.

## Boosts, userscripts, site looks

`ChromiumAddons.swift` adds them to the tab's script registrations. WebKit's
content controller takes them site by site at each navigation; a Chromium tab's
registrations outlive a page's own navigations, so all of a tab's boosts and
scripts are registered and each tests its own address (`BoostScript`,
`UserscriptRuntime`). Worlds have the same names on both engines
(`Boosts.pageWorld`, `Userscripts.pageWorld`).

The helper binds relays to isolated worlds only: `window.webkit` in a page's world
would tell sites this is Safari. A userscript in the page's world talks over
document events to a small bridge in its own world (`UserscriptRuntime.bridge`).

A boost's preview room stays a WebKit page in the same store: it checks the
boost, the person's tab then shows it.

## Tools

- Device mode: `page.emulate`, CDP's device metrics, touch and user agent.
- Site Controls' connection: `page.certificate`, read when the page finishes.
- Whole-page pictures: `page.snapshot` with a `clip` past the viewport.
- PDF: Chromium's own print. `save_page` PNG: the whole document's picture.
- Minimum font size: the profile's `webkit.webprefs.minimum_font_size`.
- `devtools_console` and `devtools_network`: the page's log (`DevRelay`), heard
  from when the card came out. Chrome's DevTools keep their own records in their
  frontend; styles, traces and comments are read there, and the tools say so.

## Honest limits

| Feature | What a person sees on a Chromium tab |
| --- | --- |
| Web archive export (`save_page`) | "Web archives are not available on this engine yet" |
| Copy Text on a picture | No row: Live Text reads WebKit's image |
| Drag the window by the top of a page | Nothing: the band is WebKit's hit-testing |
| Apple Passwords row in the page menu | No row |
| ⇧⌘T's Back history | The tab comes back without it: CEF has no way to restore a list |
| Agent's line over a page's foot | It may cover the last lines: no obscured insets |
| Password manager auto-unlock | Extensions on Chromium ask as they do in Chrome |
| Shield inside frames | Requests are blocked there; hiding rules stop at the top document |
| HTTPS-only | Yab has no such setting on either engine |
