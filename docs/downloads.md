# Downloads

At the column's foot the downloads button is always there, before the
first download too. With the tabs on top it has a place in the strip or
the address bar from the first download of a session to its end, as in
Arc: before that it takes no room beside Updates (feedback 81 and 126,
Wilford, decided 2026-10-15; the column's foot got it back the same day).
Downloads of earlier sessions are in the downloads place, ⇧⌘J. It
lives at the column's foot, or, when the tabs are on top, beside Updates
at the far end of the strip, or of the address bar when that is shown.
With the tabs on top it never stands over the page. While the column's
place can't be seen (the column put away, a page that has the screen),
the button stays at the window's bottom-left edge as a chip; a page that
has the screen with the tabs on top brings the chip out only while
something is going. A finished file rises on the chip, and 0.9 s later
the chip goes back into its edge and takes the file along; the file still
waits by the column's button until the pointer comes (owner, 2026-11-01).
A file lifts off the page where it was clicked, a dark disc, and flies an
arc into the button in 0.67 s, the arc files flew before 2026-10-30, not
up to the top of the window. Code: `Hoard.swift`
(the downloads, the button, the flight), `Loot.swift` (the last fifty
kept), `HoardStack.swift` (the column's stack).

## The stack, from the column

At the column's foot the button opens no list over the window. The files
come up out of it as plain rows, like Arc's recent downloads. Each file
is a thing to take somewhere. As in Arc, it goes with
the pointer:

- **Hover:** the pointer resting on the button for 0.18 s brings the cards
  up, when anything has been downloaded. With nothing there it brings no
  stack, only the button's tip, "All Downloads". They stay while the pointer is on the button, the cards or the row
  between, or while a button is held (a card being dragged out). They go
  0.3 s after it has left all of them.
- **Click:** the button opens every download, the downloads place (⇧⌘J).
  The pointer resting on the button for 1.1 s with the cards up says so
  beside it, in a tip: "All Downloads" and its keys.

- **As wide as the column.** Each file's edges line up with the rows.
  There are at most four latest files, fewer if the space between the
  button and the pins cannot fit them, newest nearest the button, with
  no day headers.
- **A row** is 56 points tall, without a separate background or shadow,
  measured off Arc's. It shows the file's own picture from Quick Look (a
  PDF's first page, the photo, a film's frame), cut square at 40 points
  with `Radius.small` corners; a file without a picture gets the icon Quick
  Look draws for it, whole at 40 points (its kind's icon until that comes).
  Then its name, cut at the end, and right under it, with no gap, when, in
  full words as Arc says it: "13 minutes ago", "2 days ago".
- **Under way:** the row says progress in words, in whole megabytes so it
  doesn't flicker: "144 of 452 MB · 2 min", and a thin line along the foot
  of the kind's icon fills as it comes.
  Stop Download is in its context menu. A failed download says
  "Couldn't download", with Try Again and Remove in its context menu.
- **Done:** a click opens the file. With the pointer on the row, a plate
  stands under it 4 points round the picture, curved concentric with it
  (`Radius.small + 4`), as Arc's: 48 points in the 56-point row. It reaches
  4 points past the column's edge, so the picture stays on it and nothing
  moves. Dragged out, the file itself goes,
  into the Finder, a message or a canvas. A right click has Open, Show in
  Finder and Open Downloads Folder.
- **Under it,** the sidebar rows the stack covers go while it is up, with a
  short fade across its top edge, so a row just above it stays whole. They
  come back as the files go down. The page isn't touched.
- **Motion:** the rows come up out of the button, the one nearest it
  first, 15 ms apart, on a short spring. They return top first on a
  0.2 s curve. The panel remains until every row has finished closing.
  With Reduce Motion they
  are just there. A click anywhere else, Escape, the app put away or the
  window resized also puts it away. The column put away, or let go when
  it was out over the page, takes the cards with it, as far and on its
  own curve, at once: they are its rows.

It is a panel of its own over the column (`HoardStack`, a borderless child
window that casts no shadow of its own), as the Tray is. A download's
numbers change ten times a second. In the window's one hosting view, that
would work out the whole window again each time. The panel keeps room
round the cards for their shadows and reaches down over the button, so a
click on the button lands in the panel, which takes it there. Where the
pointer is gets read ten times a second while the cards are up, instead of
tracked: the panel comes up over a pointer that hasn't moved, and the
button under it would never hear it leave.

## The list, from the strip and the chip

From the strip or the chip, the button keeps the Tray's list
(`HoardList`), built like the extensions list: a row per file, 40 points
tall, then Open Downloads Folder and All Downloads.

## A folder closed to Yab

Before WebKit is handed a file, Yab writes a stand-in in the folder
downloads go to, off the main thread (`DownloadFolder.swift`). macOS keeps
Downloads, Desktop and Documents closed until Files & Folders opens them,
and WebKit's write there waits on macOS's question: when that question
never came up, the download said "in progress" forever and no file came
(#400). Now a folder that refuses the stand-in, or hasn't answered in 4 s,
gets nothing: the file goes to Yab's own folder (`Downloads` in Yab's
Application Support folder) and the corner says "macOS keeps Downloads
closed to Yab" with Open Settings (a folder that isn't macOS's to close:
"Can't save in" and its name), once a folder while Yab runs. The next
download asks again, so a switch turned on meanwhile counts at once. A
missing folder is made first. `evals/download-stuck/check.py` covers every
kind of download, a folder without write permission and one macOS never
answers for.

## The bench

`{"do": "hoard"}` says the button's state, and the stack's window and
frame. In a test world it also takes `keep` (files remembered as
downloaded, `[{path, from, minutes}]`), `pretend` (a download that isn't
one, `{name, from, got, total}`), `stack` (up or down, held: the pointer doesn't put it away) and `calm` (the
field put away). `work/design/downloads-sidebar-2026-10-02/probe.py`
pictures it all, light and dark, with frames of the opening.

### First-hover readiness and shared pictures

The first hover waits for the stack's measured rows and their icon geometry
before raising the cards and handing off the waiting file. An empty hosting
view is not an acknowledgement: layout and the row reader retry the same
opening without requiring pointer reentry. Closing cancels that opening.
The pointer expiry clock starts only after the rows mount.

`HoardPictures` shares Quick Look requests and results by standardized file
URL and filesystem modification date. Loot warms the picture when the file
is completed. The waiting file, its carrier, the list rows and the cards use that
picture. Rows and cards show a quiet square until it arrives (the kind icon
first and the picture after read as two different files); the waiting file
has it by the time it lands, or keeps its kind icon until then. Files Quick
Look has no picture for keep the kind icon. The flight keeps its dark disc.
The Finder edge and square crop come from the same drawing; these are file pictures, not floating cards, so they do
not take `.cardFrame()`'s padding, ground or shadow.

`HoardOpeningTests` covers delayed mount, cancellation and picture revision
keys. `evals/golden/download_first_hover.py` runs the badge probe's cold,
pinned-column and floating-column first hovers with real pointer events.
Native compilation, the suites and the reporter's scenario are deferred in
`qa/pending/downloads-first-hover-and-thumbnails.json`, not yet verified.
