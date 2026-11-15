# Where a new tab lands

Feedback 43 (Yab 0.0.8) asked for new tabs after the current tab rather
than above it. Yab follows Arc here, so Arc was measured first, case by
case, and Yab was made to do the same. No setting: Arc has none.

Code: `Placement.swift` (`linkLanding`, `askedLanding`), `Browser.open(_:foreground:atEnd:from:shy:linked:)`,
`Browser.webView(_:createWebViewWith:for:windowFeatures:)`, `Browser.duplicate()`,
`Research.swift` (`openBeside`). Tests: `TabPlacementTests` (the rule as a
case table, and in a window). Probe: `evals/tab-placement`.

## How Arc was measured

Arc 1.167.0 on main, 2026-10-04, in an existing space with one pinned tab
and a few of today's. Each action was posted to Arc with `CGEventPostToPid`
(keys) and HID mouse events (clicks on links and rows), only after the
Mac had been idle 45 s, under a countdown banner; the sidebar's order was
read through Accessibility (`sidebarAllTabList` rows) before and after
each step. The pages came from `python3 -m http.server` on 127.0.0.1, all
titled `ZQ …`, with plain links, `target=_blank` links, a `window.open`
button and a sized `window.open`. Every tab the study opened was closed,
pinned ones unpinned first, and windows it opened closed. Arc's settings
were read, not changed: `openExternalLinksInLittleBrowserEnabled` was off,
so links from other apps open as tabs in the space.

Arc's column: favorites (squares) at the top, then pinned tabs, a line,
the "+ New Tab" row, then today's tabs, **newest at the top**. In Yab the
same parts are pins, kept tabs, the line and today's tabs.

## Arc's rules

| How the tab is opened | Where Arc puts it | In front? |
|---|---|---|
| ⌘T, then a place (Return) | top of today's, under + New Tab | yes |
| The "+ New Tab" row, then a place | top of today's | yes |
| ⌘T, then ⌘Return | top of today's | no, the page stays |
| ⌘T, then ⇧Return | top of today's | yes (same as Return) |
| ⌘T, then ⌥Return | no row: the page showed over the current one (a Peek, by its look) and Escape put it away | - |
| ⌘T, then ⌃Return | nothing opened | - |
| Link from another app (`open -a Arc URL`, Arc as the default browser) | top of today's | yes |
| ⌘-click a link | right after the page | no |
| Middle click | right after the page | no |
| ⌘⇧-click | right after the page | yes |
| Link with `target=_blank` | right after the page | yes |
| `window.open` from the page | right after the page | yes |
| ⌘-click on a `target=_blank` link | right after the page | no |
| Several links from one page in a row (any of the above mixed) | each after the ones before it: the page's links stack below it **in the order they were opened** | as above |
| ... after going to another tab and back | the stack goes on: still after the earlier ones | |
| A link from one of those links (a grandchild) | right after that link's tab; the page's next link goes after the grandchild too, so a page's whole family stays together | |
| Duplicate Current Tab (command bar) | right after the original; the original stays in front | no |
| ⌘⇧T after ⌘W | back where it was (even with another tab in front) | yes |
| From a pinned tab: ⌘-click | top of today's | no |
| From a pinned tab: more ⌘-clicks | after the first, in order, at the top of today's | no |
| From a pinned tab: `target=_blank` | no row: a Peek over the pinned tab; Escape closes it | - |
| From a pinned tab: ⌘T | top of today's | yes |
| Split View, ⌘-click in the left page | after the pair (Arc shows the pair as one row) | no |
| Split View, ⌘-click in the right page | right after the pair, above the left page's links | no |
| Inside a folder (folders live among the pinned) | not measured: the command bar's "New Folder from Selection" made no folder, and dragging was not done to the user's Arc | |
| From a favorite | not measured: favorites can only be made by dragging, which the study did not do to the user's Arc | |

The same rule covers every link a page opens: **after the page, after
everything the page (and what it opened) already put there.** A tab you ask
for yourself goes to the top of today's. A page above the line (pinned)
starts its stack at the top of today's.

With the column or the strip across the top put away (⌘S, not out over
the page), a tab opened behind the page has no row to show for it, so the
corner shows the page: its favicon, its name and Go There, for 4 s and for
as long as the pointer is on it. The name is the link's own words (WebKit's
`linkLabel` under the pointer), or else the page's title as soon as it has
one (a second at most), or else its site, cut to fit (`Browser.openedName`,
`Browser.sayBehind`, #239, register 1168; evals/ask-239). Every way of
opening a tab behind says it: a link, a site's own `window.open` under ⌘, a
bookmark, the field. With the tabs in sight the new row says it and nothing
pops.

## Yab before, and the differences

| Case | Yab before | Arc |
|---|---|---|
| ⌘-click, middle click, ⌘⇧-click | top of today's, so several came out newest first, far from the page | right after the page, stacked in order |
| `target=_blank`, `window.open`, Open Link in New Tab | the very bottom of the row | right after the page, stacked in order |
| ⌘-click from a kept tab (Arc: pinned) | top of today's, newest first | top of today's, in order |
| `target=_blank` from a kept tab or a pin | a tab at the bottom of the row | a Peek, no row |
| ⌘D, Duplicate | top of today's, in front | right after the page, the page stays in front |
| ⌘T, the plus, a typed place, another app's link, ⌘Return | top of today's | same |
| ⌘⇧T | back where it was | same |
| Split View | (follows the rows above) | after the pair, the right half's links first |

## Yab now

`Browser.linkLanding` is the rule, a pure function over the row (tested as
a case table in `TabPlacementTests.caseTable`):

- A page in today's tabs: the index after it (after its pair's other half
  when it is the left half of a Split View pair), then past every tab that
  this page or one of those tabs opened (`Tab.linkedFrom`).
- A pin or a kept tab: the same, starting at the top of today's.
- No page: the top of today's.

`linkedFrom` is set only for tabs a page opened (⌘-click, the middle
button, `target=_blank`, `window.open`), never for one you asked for, so a
typed place never joins a page's stack. It lives as long as the window;
it is not written to the session.

Unchanged on purpose: anything you ask for (⌘T, the plus, the field's
modifiers, bookmarks, links from other apps) goes to the top of today's
in the column (across the top, see below); ⌘⇧T puts a tab back where it
stood; a search folder still gathers what its results page opens
(`gatherSearch`); an agent's tabs keep to the end.

With Settings › Tabs' "⌘-clicking links makes folders" on (on unless
turned off, as Dia's auto groups, docs/link-folders.md), a ⌘-click or a
middle click from one of today's pages lands in the same place and the page
and its links become a folder of today's there: the order above holds, the
folder only wraps it. From a pin or a kept tab the links still go to the
top of today's, in order, and from the second on they are a folder there,
the pin or kept tab left out, as Dia does from its favorites.

## Across the top

Feedback 55 and 61 (Yab 0.0.9 and 0.0.10, Settings › Appearance ›
Sidebar: Off): with the tabs in a strip across the top, a tab asked for
went to the far left, the strip's "top of today's", while the plus that
asked for it is at the right. The rule was written for the column, where
New Tab is the row over today's and the new tab comes in right under it;
in the strip the same index is the opposite end from the plus, and often
out of sight in a full strip.

So the strip does what Chrome and Safari do: anything you ask for (⌘T,
the plus, the field's modifiers, bookmarks, links from other apps) goes to
the end of the strip, beside the plus. An agent's task folders keep to the
end of the row (`Folders.gather`), so with one in the strip a tab you ask
for lands just before the task's folders, the last of your own tabs.
`Browser.askedLanding` is the rule, tested as a case table in
`TabPlacementTests.askedForCaseTable` and in a window in
`acrossTheTopATabYouAskForGoesToTheEnd`; `evals/tab-strip` checks it in a
real window, through ⌘T's field. The column keeps Arc's order. A page's
links (`linkLanding`), Duplicate and ⌘⇧T are the same in both: right after
the page, in order, and back where it stood. A copy of a pin or a kept tab
goes to the top of today's in the strip too, just past the pins, rather
than to the far end (`acrossTheTopADuplicateStaysByItsPage`). No setting:
Chrome and Safari have none for their strips, and Arc has none for its
column.

## Not matched or not measured

- ⌥Return in Arc's command bar showed the page without a row; Yab's
  ⌥Return still opens a tab in front at the top of today's.
- Favorites and Arc folders: not measured (see the table). Yab treats a pin
  and a tab in a kept folder as above the line: the top of today's.
- A sized `window.open` (a pop-up) and links at launch from another app
  were not measured; Yab keeps its own handling.
- "Open Image in New Tab" and "Search for" from a page's menu were not
  measured; they still go to the top of today's.
