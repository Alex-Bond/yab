# No empty tabs

A tab comes with its page, never before. ⌘T, the plus and Split View put
the field over the page you are on and ask where to go; the tab or the half
is made when you answer, with the place in it. ⌘N opens a window at once,
as Arc's does, and the field asks on that window's own ground for its
first tab (feedback #285: asked over the page, it read as a new tab).
Normal and private windows can start without a tab; Escape hides their
field and leaves the window. The column's New tab row is a way to ask,
lit while the field asks for its tab (docs/kept-tabs.md, "New tab's row").

Code: `Browser.swift` (`asked`, `asking`, `place`, `Under`, `askNew`,
`backOut`, `newTab`, `newWindow`), the stage under the field in `App.swift`,
`Spaces.swift` (`switchSpace`), Split View's in `Split.swift`. Tests:
`NoEmptyTabTests`.

## What asks

| Key | Over a page | Return makes |
|---|---|---|
| ⌘T, the plus | the field, empty | a tab beside the page |
| Split View (⌘T's list, the menu) | the field, empty | a tab beside the page, the two side by side |
| ⌘L | the field, the page's address | the page goes there |

`asked` says which of the first two the field is asking; nil is ⌘L's.
`asking` is what a place chosen now would make, read before the field goes,
which lets go of it, and `place` makes it. The foot of the list says it in
words: Open in New Tab, Open in Split View, Open.

From a private tab ⌘T is a private tab, as before.

## ⌘N

File › New Window, ⌘N, opens a window of the space you are in at once, its
pins and kept tabs asleep in its column (docs/kept-tabs.md), nothing in
front, and the field on its ground asking for its first tab, as a window
with nothing in it always does (below). Return opens the place as that
window's first tab; Escape hides the field, clears what was typed and
leaves the empty window. ⌘T's field, if it was up in the window ⌘N was pressed in, goes.
Arc and Dia both open a window at once on ⌘N (evals/new-window/arc_dia.py).
Code: `Browser.newWindow`, `BrowserWindows.newWindow`.

## With no tab in front

Some moments leave nothing in front: the last tab closed, a space with
nothing in it, a new window, a first launch. `activeID` is nil then, the
field stands up without being asked (`fieldShowing`), and it asks for a tab
of its own (`fresh`). The column keeps its address plate, saying "Search or
type a URL" (`EmptyPlate`), so the pins and rows under it stay where they
were. ⌘W with nothing in front closes the window when only pins and kept
tabs remain in the column, as well as when no tabs remain. Closing an active
pin or kept tab first puts it down and retains its row; another ⌘W closes
the window. The field may be shown, hidden or have unsubmitted text.
Ordinary background pages and a previous space's page under the field
keep their existing behavior. Escape can hide the field in an empty normal or
private window; ⌘T shows it again, and ⌘T again hides it.

What stands under the field then is `under`:

- **⌘W on the last tab.** It closes as any other, into Recently Closed,
  and the field stands on the window's own ground. Escape brings nothing
  back; ⌘⇧T does.
- **A space with nothing in it**, made new or gone to: its column, empty,
  and the page you were on under the field, still in its own space's row.
  Escape takes you back to that space. A space with kept tabs or pins of
  its own and none in front (each put down with ⌘W) is not empty: the
  field stands on the window's own ground there, as Arc's empty window,
  never over the last space's page (feedback #370, `KeptOnlySpaceTests`).
  Escape there, or a click beside the field, puts it away and leaves the
  column free to pick a tab (`fieldPutAway`); ⌘T, ⌘L, a tab in front or
  another space raises it again. If the last kept tab or pin leaves the
  column, dismissal resets and the field is available again even without
  a tab selection; a later synced tab does not hide it again. Shared pins
  alone do not count as the space's own tabs. A private window with an
  actual blank tab retains its existing field behavior.
- **Nothing at all**, the last tab closed, a new window or a first launch
  with no tabs: the field on the window's own ground, no card under it.
  Escape hides the field and clears what was typed; ⌘T shows it again.
  Another ⌘T hides it, and ⌘W closes the empty window.

Choosing another tab, or another space, while the field stands there lets
what was under it go (`settleUnder`), as does closing the window.

A window opened with nothing in it builds a spare tab's web view a second
later (`warmSpare`), so the first address typed finds WebKit running, as the
empty tab used to; the first page opened takes that tab.

## Everything else that used an empty tab

- A link from another app, Open All, a space's pages: new tabs, since there
  is no empty one to fill.
- An extension's own new tab page, once you said yes to it, is a real page
  and opens as one; the question is asked over ⌘T's field, and a yes opens
  the page in place of the field.
- An answer asked in the field with nothing in front runs on the page
  under it, or on the spare tab (`holder`).
- The welcome's picture of your window has no live tab until a link has
  landed, and no card under the field.
