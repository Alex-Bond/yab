# Link previews

Settings > AI > While You Browse > Link Previews controls the cards (on by
default). Hold Shift over a web link, on every site; plain hover never
opens a card (X, Hacker News and search results once did, until
2026-10-21). A link only passed over makes no request. A selection or recent
text caret takes precedence over Shift, as it does for Peek (#204).

The measured Arc study and proposal are at
https://yab-arc-previews.vercel.app. The timings are observations and fitted
curves, not constants extracted from Arc's code.

## Lifecycle

`LinkCardRules` holds eligibility and placement. `LinkCard` belongs to a
browser window; native mouse and modifier events start its timer. Shift
also works when the pointer is already resting on a link. The main
frame's small script in `PageScripts` finds the actual anchor and its box,
with page zoom accounted for. Hit testing waits for 25 ms without motion,
instead of sending a DOM query for every mouse move. After 130 ms it highlights the link; after
430 ms of rest it may read the page. There is no per-mousemove script
message handler on every page or dependency on WebKit's private status-link callback.

`LinkCardLoad` owns at most one warm page, configured with the source's
website data store and privacy mode. The page is outside the tab row,
session and history. Hover never offers its popups, downloads, JavaScript
dialogs or media capture. Only a main-document failure invalidates the preview;
a failed embedded frame does not. Loading is bounded to about twelve seconds.

Once metadata is available, the card shows the title, site and loading
bars. `LinkSummary.preview` streams an eight-word summary and up to three
facts from Apple Intelligence on this Mac. When its default guardrails
refuse a page (interface.club's farewell post did, on main), it asks once
more with `.permissiveContentTransformations`, which only answers plain
text, so in the JSON below. Without it (off, as on adhd, or
failing), the AI connected in Settings › Agents writes them, yours first:
Claude's Haiku kept warm (`LinkSummary.reader`, started when Shift comes
down on a link, never thinking, 12 s at most), or Codex's cheap model
(`LinkFolders.codexModel`, gpt-6-luna in October 2026) at low effort with
no tools, 30 s at most. Each answers one line of JSON (`LinkSummary.parse`).
A private page is never sent to them. With none of these, the card keeps
the page's own description. Page content is data,
not instructions to the model. Images are downsampled thumbnails. A load
failure gets “No preview for this page.” instead.

The 296 pt card is a nonactivating child window with Yab's floating corners,
colors and motion. It can hang past the browser's bounds; screen bounds
alone constrain it. At the bottom of the screen it moves above the link.
The pointer may move onto the card, whose Share button shares its words and
address. A click on its body does nothing. Escape leaves it up. Leaving the
link and card waits 80 ms, then collapses and fades for 140 ms. Scrolling,
changing tabs, navigating, turning the setting off or leaving the app puts
it away. Its own tracking area hears exits straight onto the desktop too.

A Shift-click uses `Browser.peek` as before. It takes the warm `Tab`, even
if its load is still underway, and the card's picture and screen rectangle
become `PeekOrigin`. No second navigation is started for that page.

Completed summaries stay in memory for up to a day, with at most 48 entries
per browser, partitioned by cookie store and URL. They never go to disk.
Private pages do not enter that cache. A completed warm page is kept for
30 seconds after leaving; an unfinished or private one closes immediately.
Cancelled requests, old layout callbacks and out-of-order DOM replies cannot update another
link's card. The ordinary tab's status pill remains unchanged.

## Verification

`LinkCardTests` covers modifiers, selection, URL schemes, screen placement,
metadata, output limits and real DOM selectors. `LinkSummaryTests`,
`LinkPeekRoutingTests` and `PageScriptsTests` hold neighboring behavior.
Run these through the farm, never a compiler directly on the user's Mac.

`evals/link-cards/run.sh MAIN_COMMIT` builds that actual main and the frozen
candidate in one display farm job, then runs `check.py` in two fresh worlds.
Its local fixture counts requests and verifies its cookie reaches the
preloaded page. It records native frames, then checks hover, passing,
Escape, caching, adoption into Peek, the switch, Shift, selection, stale
results, error, scrolling and edge placement. `bench linkcard` and its
synthetic native pointer are restricted to test worlds. `film` with
`linkcards: true` includes the child window in native layer recordings.
Acceptance results and inspected frames are kept in the task's work folder;
a successful compile alone is not visual acceptance.

## Acceptance on 2026-10-20

Frozen candidate `f62961bc2510` was built in farm job
`845bcf441d7e435a` against actual main
`447f44137a3a6ffc31a068bb01925966e18b9149`. Both app names were checked;
27 native checks passed. Job `9dbee3ea3cbc45a3` reused those exact apps,
added full child-window captures, closing frames and physical screen-edge
checks, and passed 29 checks. Its candidate input executable SHA-256 is
`086fb76bd83829dcd33b5ae719da318254d0b4b45fb2921f6c231c5f2c8b8eb6`.

The earlier focused unit job `6b5d7cab91004d24` passed 16 tests in four
suites. Later controller changes are covered by the native runs; this is
not a claim that the entire current FastTests suite was run.

Before/after opening frames, closing frames and full card captures were
inspected. Physical bottom/right placement passed with the real window and
screen coordinates. The initial SCK child-window picture compressed the
parent window and is not accepted as an isolated-card capture; the later
native `winshot` captures show each complete card. The additional Peek
layer recording has an intermediate frame without WebKit contents and is
not used as proof of a seamless visual handoff. Actual Peek visibility,
history and reuse without a second page request passed.

Apple Intelligence was unavailable on the test hosts. Page-description
fallback is verified; live generated summaries and facts remain unverified.
The native acceptance uses isolated fixture profiles, not authenticated live
accounts on all six supported services. Settings integration uses the shared While You Browse page. The parent
compiled the composed product source in job `8ec40606309d4267`; its exact
source and binary receipts are retained with the acceptance records.
A local product commit does not imply a push or release.

## Post-acceptance source review

Source review found a missing invalidation path when the same tab commits
while its DOM hit-test is unanswered and no Pointed exists yet. This race
has not been reproduced at runtime. The follow-up binds every queued read
and callback to a source-owned ticket. `forget` cancels that source's ticket
before considering Pointed, so an old-document reply is rejected even when
activeID and the URL stay unchanged. Other tabs' commits preserve the read.

Two deterministic callback-ordering regressions were added to
`LinkCardTests`: old reply after commit rejected, new reply accepted and
protected from a late old reply; queued work invalidated while another
source's commit leaves it valid. All seven LinkCard tests, including both
callback-ordering regressions, passed in composed-source job
`f71923f6bdec465d`. The 29 native checks and published recordings above
remain evidence for their preceding exact binary and unchanged UI; the
new invalidation path is covered by the focused regression tests.
