# The column's header row and its door

The row at the top of the sidebar holds the traffic lights, the column's own
door, and back, forward and reload held against the right margin. The door
does what ⌘S does (Browser.toggleColumn). Requests #250b and #287; placed
by the Oct 20, 2026 1:1 mockup (variant H,
`work/visualizations/toggle-1to1/`), its mark changed on Oct 21 to Arc's
sidebar mark. Code: `Sources/Fast/ColumnDoor.swift` (ColumnHead,
ColumnDoor, HelmMore), the row in `Side.swift`.

## Where things stand

- Lights: 14 pt, centers 26, 49 and 72 from the window's edge.
- The door: a header door (30 pt), its center 28 pt from the green light's,
  as Arc has it: x 85 to 115. Its mark is Central's sidebar-simple-left-wide
  (`sidebar.left`), the closest of Central's to Arc's; the same in the card
  when the column is put away, as Arc's, never turned. A right column wears
  sidebar-simple-right-wide (`sidebar.right`).
- Back, forward and reload: against the right margin 8, 35 apart (30 + 5;
  Compact 30 + 4).
- Tip: "Hide Sidebar" or "Show Sidebar" with the live keys, after 0.7 s.
- No reading mode book in this row: reading mode is ⌥⌘R and the menus.

## What folds, and when

Worked out from the door sizes and the density, never written as numbers
(ColumnHead.fit):

| Column | Comfortable | Compact | Row |
|---|---|---|---|
| Everything | from 228 | from 225 | lights, door, ← → ↻ |
| Narrow | 180 to 227 | 174 to 224 | lights, ← → ⋯ |
| Narrowest | 164 to 179 | 164 to 173 | lights, ← → ⋯ on Arc's 26 pt doors, 28 apart |

The column goes as narrow as Arc's, 164 (request #1094; Arc holds its
edge between 164 and 500, `evals/side-width/arc_min.py`). Under the folded
row's width the doors shrink to Arc's own at that width (ColumnHead.doors).

"⋯" is the Mac's own menu: Reload (Stop while loading) and Hide Sidebar,
each with its keys. It shows a cross while open.

## Other modes

- Put away: the card the edge brings out has the same door; pressing it
  puts the column back. The 0.33.2 click on the column's edge still hides it.
- Column on the right: the lights are over the page (HeadBand), the doors
  at the inner end and the door at the outer one. Everything fits at the
  narrowest.
- Mail: lights, the door, New Mail on the right. A tab in mail's space has
  the usual row and thresholds.
- Split View: lights and the door; each half has its own back, forward and
  reload.
- Full screen: the same door after the lights, the column docked or out
  as a card (feedback #274; Arc keeps its sidebar button there too).
  `evals/column-door/fullscreen.py` pictures it, `full_ab.sh BASE` before
  and after.
- Tabs across the top: no column, no door.

## Checking it

`evals/column-door/shots.py` pictures the row in both looks at the
threshold widths, Compact, the "⋯" menu, put away and the card, the right
side and Mail, and measures the door's frame and mark against the numbers
above; `evals/column-door/ab.sh BASE` runs it on a base build and this one
in one farm job. `Tests/FastTests/ColumnHeadTests.swift` holds the
thresholds.
