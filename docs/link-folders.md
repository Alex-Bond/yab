# ⌘-clicking links makes folders

Feedback #138 and register row 203 asked for Dia's auto groups: a ⌘-click
(or a middle click) on a link makes a group of the page and the tab it
opened, and more links from that page join it. Yab copies Dia's behavior
and numbers. Dia was filmed frame by frame on 2026-10-16 (Dia 1.52.0,
`docs/evidence/folder-motion-2026-10-16/`, scripts in
`evals/folder-motion/`). Yab's group is a folder of today's (a `Nest`,
`Kept.swift`), the same object a search's folder and a folder you make of
two of today's tabs already are, not a new kind of thing.

Code: `Research.swift` (`gatherSearch`, `gatherLinks`, `join`),
`LinkFolders.swift` (the name), `LinkFolderViews.swift` (the bar, the
shimmer, the mark), `ColumnMotion.linkFolder` / `folderClose` and
`ColumnMotion.Hint` (the springs), `Browser.close` (the hint on a close).
Tests: `LinkFoldersTests`. Eval: `evals/cmd-click-folders/`.

## The switch

Settings › Tabs › **⌘-clicking links makes folders**, on unless turned off,
as Dia's `⌘-clicking links creates tab groups` (on in the user's profile;
the user picked Dia's default on 2026-10-16). Arc has no such thing and puts
a ⌘-clicked link right after its page (docs/tab-placement.md): with the
switch off, Yab does that for results pages and ordinary pages alike:
links open as plain tabs in the order they were opened. On, a link
opened from a page in any folder of today's (one a ⌘-click made, one you
made of two tabs) goes into that folder too.

## Dia, and Yab

| | Dia 1.52 | Yab |
|---|---|---|
| ⌘-click or middle click from a page of today's | the page and the link become a group where the page stood; the page drops one row and steps in, the header comes in above it, the link fades in under it | the same: a folder of today's (`Nest.fleeting`, `Nest.linked`), page first, link second |
| The motion | nothing for 150–210 ms (the tab being made), then one spring, response 0.17 s, damping 0.85, settled by 280–330 ms | `ColumnMotion.linkFolder`, response 0.17, damping 0.85, on the column's layers |
| Another ⌘-click from the page or one of its links | joins after the group's last tab, new row in place by 293 ms | joins after the folder's last tab (`join`), same spring |
| The name, while waiting | a gray bar, a faint light passing left to right (0.55 s, every 1 s) | `LinkFolderPlaceholder`, the same |
| The name | the AI's, 2–4 words from the group's contents, at 1.1–1.7 s (the model's time) | the cheap model of the AI you connected in Yab, yours first: Claude Haiku, kept running while a ⌘-click folder could be made and never thinking (`LinkFolders.namer`, a `WarmClaude`), or Codex's fast and affordable model at low effort (`codex exec`), with no tools, Codex run once as `PostWriter` runs it; Apple Intelligence on the Mac only when none is connected or answers (`LinkFolders.agent`, `.model`), with Dia's own prompt words. Measured on adhd: cold `claude -p` landed it 8.0 s after the click, about 1 s of it Claude Code's start and the rest Haiku thinking (the Mac's Claude settings turn it on); warm and with thinking off, 1.2 s (eval 16/16, farm job aa4780f4) (`evals/cmd-click-folders/warm_timing.py`: an ask 0.7 s warm, 2.1–4.3 s with thinking). Haiku starts when a page comes in front with the switch on, and goes after ten minutes without one: 127 MB footprint while it runs (Activity Monitor's Memory; 208 MB resident). Without it, a cold `claude -p` with thinking off took 2.4–3.8 s on adhd (8 runs, `warm_timing.py --cold`), short of Dia's, so it stays warm |
| The name landing | a band, blue, white, gold, pink, crosses it left to right at about 200 pt/s, done 770–880 ms after; the icon's blue wash wipes off | `LinkFolderShimmer` and `LinkFolderMark`, the same colors and speed |
| Later tabs | no rename, no shimmer | named once: a join keeps the name |
| No AI name | `Group 1`, `Group 2` (local pages) | `Folder 1`, `Folder 2` when the Mac has no model or it gives no name that fits |
| A name you type | kept | kept: typing while the bar shows takes the bar away (`Nest.name`'s didSet), and the model's answer never writes over it |
| The group's icon | its tabs of one site: the site's favicon; of more: an emoji (see below), or a gray folder with the emoji switch off | the same (`LinkFolders.mark`) |
| ⌘W inside the group | the rows below close up on response 0.205, damping 0.80 | `ColumnMotion.folderClose` |
| Down to one tab | ungrouped in one frame, no animation | the folder goes (`Folders.settle`), the column laid without animation (`ColumnMotion.Hint.still`) |
| The page closed first | the group stays with its links | the same |
| `target=_blank` from a page in the group | joins the group, right after the page | the same (`webView(_:createWebViewWith:…)`) |
| From a pinned tab (Dia's favorites) | see below | see below |
| Pins, kept tabs, an agent's tabs, a Split View pair | | no folder (`gatherSearch`'s guard) |

What Yab does not copy: Dia names a group of local pages (127.0.0.1)
`Group N` and never asks its model. Yab asks for every folder: the titles
go to the AI you connected yourself, or stay on the Mac.

## From a pinned tab

Measured on Dia 1.52.0 on m4, 2026-10-16 (farm job `421565bc…`,
`evals/folder-motion/dia.py blank favorite`, its two steps in
`evals/cmd-click-folders/folder-motion-dia-steps.patch`, pictures and accessibility
dumps in `docs/evidence/cmd-click-folders-2026-10-16/dia-favorite-and-blank/`).
The page was pinned from its row's menu (Dia's Pin makes it a favorite
square at the top), then ⌘-clicked twice:

- The first ⌘-click opens the link as a plain row of today's, in no group.
- The second makes `Group 1` of the two links. The favorite stays a
  favorite, outside the group (`CmdClickFavoriteTabLinksGroupingController`).

Yab does the same from a pin or a kept tab (`gatherFromAbove`): the first
link lands at the top of today's as Arc's does (docs/tab-placement.md), the
second makes a folder of the two there, later ones join it. Off, neither.

In the same run, a plain click on a `target=_blank` link from a page in a
group put the new tab in the group right after the page, above the link
⌘-clicked before it.

## A search's folder

With the switch on, a results page's ⌘-clicks make a search's folder named
for the words searched, and that name is never the model's (`Research.name`).
With it off, ⌘-clicks open plain tabs after the results page and its earlier
links, just as on an ordinary page. Existing folders stay, but new links
from their pages do not join them while the switch is off. The ⌘-click
folder and the search's share the code: `gatherSearch` makes the one or the
other, `join` fills both.

## The emoji

Settings › Tabs › **Add emoji to new folders**, on unless turned off, as
Dia's `Add emoji to new tab groups` (on in the user's profile). Measured on
Dia 1.52.0 on m4, 2026-10-20 (`evals/folder-motion/dia.py webx:… toggle:emoji:…`,
pictures in `docs/evidence/link-folders-2026-10-20/dia/`):

- A group of pages from more than one site (Hacker News and the
  Mastodon post it linked to) wears an emoji in place of the favicon:
  📰 for "Tech News & AI" and "Tech Reading". It lands with the name, in
  the same frame, about 3 s after the click there (the model's time), and
  gets the same blue wash and shimmer the favicon gets
  (`emoji-landing-frames.png`).
- The same with the switch off (Lobsters and its links): a gray folder
  mark, no emoji, no favicon (`emoji-off-two-sites.png`).
- A group of one site, the switch on (Wikipedia's Bagel, Bread roll,
  Poland): the site's favicon, no emoji (`emoji-on-one-site.png`). Local
  pages get no name and a gray folder, as before.

Yab: the emoji comes from the same call as the name, never a second one.
With the switch on and the folder's pages of more than one site (hosts,
`www.` aside), the namer is asked to start its answer with one emoji
(`LinkFolders.emojiAsk`; Apple Intelligence's `FolderNameEmoji`), the
answer is split into the emoji and the name (`LinkFolders.split`), and the
emoji becomes the folder's mark (`Nest.customMark`, so it is written to the
session and synced like a mark you pick) unless you picked one meanwhile.
`LinkFolders.mark` decides what the row wears: the site's icon for one
site, the emoji, or the folder's own mark.

## ⌥⇧-click on a tab

Settings › Tabs › **⌥⇧-clicking a tab makes a folder**, on unless turned
off, as Dia's `⌥-⇧-click opens tab in group` (on in the user's profile;
Dia's own words for it: "creating tab groups when opt-shift-clicking
Tabs"). Measured the same day:

- ⌥⇧-click on another tab's row, the tab in front in no group: the two
  become `Group 1`, the tab in front first, at the end of Dia's pinned
  tabs, above the line (`opt-shift-row-pinned-group.png`). One motion: the
  header fades in at about 110 ms, both rows fly into it, settled by
  about 233 ms (`opt-shift-row-frames.png`), the ⌘-click spring.
- The tab in front in a group (one a ⌘-click made): the clicked tab joins
  that group, last (`opt-shift-into-group-before.png`, `-after.png`).
- Off: ⌥⇧-click picks the two, as ⇧-click does
  (`opt-shift-off-picks-both.png`).
- ⌥⇧-click on a link in the page is not this: Dia opens the link in
  Split View beside the page (`opt-shift-link-split.png`), as Yab's ⌥-click
  already does.

Yab: `Browser.groupClick` (Research.swift), read from the row's keys by
`Browser.rowClick`. In no folder: a kept folder (Yab's kept is Dia's
pinned) at the end of the kept, the page in front first and still in
front, named as a ⌘-click folder is (the bar, the model, the shimmer) and
wearing its mark. In a folder: the tab joins it after its last tab, kept
or today's as that folder is. Off, or on a pin, on the page in front, on
an agent's tab: as before (⇧'s pick, or a plain click). One ⌘Z puts it
back.

## Kept across a relaunch

A folder's `linked` mark is written on its tabs in the session
(`Session.Entry.folderLinked`) and synced (`SyncFolder.linked`), so after a
relaunch, and on another Mac, a ⌘-click or ⌥⇧-click folder still wears its
site or its emoji. Sessions written before read as before: no mark.

## Meetings

Settings › Tabs › **Group tabs for meetings**, on unless turned off, as
Dia's `Automatically group tabs for meetings` (on in the user's profile).

Read from Dia 1.53.0's code, not filmed (`MeetingTabGroups`,
`WindowBrowserContextMeetingsController`, `CalendarPreview`): a meeting
group is made when a meeting is joined from Dia's calendar (its meeting
reminder's Join, or "Open All and Join", which also opens the event's prep
links an AI picks, `FilterMeetingLinksPrompt`), keyed on the calendar
event (id, account, start, end, join link, title), named for the event (a
fallback title without one), and its header counts the time left (`Time
remaining string for meeting tab group`). The filming was tried on
2026-10-20 with an event made for it (deleted after): Dia on m4 and on adhd
is signed in to no Google account, so it read no calendar and gave no
reminder (`evals/folder-motion/dia.py meeting:…`, `pincal`).

Yab (`MeetingFolders.swift`): Join (the reminder, a pinned calendar's,
⌃⌘J) puts the call's tab in a folder of today's named for the meeting
(`Meeting` when it has no title). The folder stays with only the call in it
until the meeting ends (`Nest.staysAlone`), says the minutes left on its row
(`MeetingLeftWords`, "12m left"), and takes what you ⌘-click from the call.
Not copied: Dia's prep links (Yab's meetings carry no links of their own),
and what Dia does when the meeting ends, which wasn't seen. A meeting's
folder is not written as one: after a relaunch it is a folder of today's.

## Not built

Dia's "Open All and Join" with its prep links, and filming Dia's meeting
groups: both wait for a Dia on the farm signed in to a Google calendar.
