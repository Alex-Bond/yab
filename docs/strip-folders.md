# Folders on top: the capsule

How a folder looks and moves in the row of tabs on top (not the column).
Folders of yours (`Nest`: kept folders and a search's folder) and an agent's
task folder are drawn the same way. Code: `TabBar.swift` (the row, its widths,
the capsule behind a folder), `KeptViews.swift` (`NestPill`),
`AgentFolders.swift` (`FolderPill`, `FolderPillPlace`, `Folders.lay`),
`StripWidths` (the widths, apart from the view, tested in `StripWidthsTests`).
The column is described in [kept-tabs.md](kept-tabs.md).

Chosen on 2026-09-26 out of four sketches (capsule, tray under the pill, a
deck of favicons, the row swapped for the folder's tabs). The capsule keeps
the folder's tabs in the row, where a tab is picked and dragged, and gives
the folder an edge.

## What was wrong

- **Opening one folder squeezed the whole row.** Every loose tab had one width
  (`width(in:)`: the room over the count of everything shown). A folder of
  three opening added three to the count, so every tab in the row lost width
  at once, and past a dozen they all dropped their titles together
  (`docs/shots/2026-09-26/kept-review/strip_light_2_open.png`: the row
  becomes a line of dots, the folder its bare mark).
- **An open folder had no edge.** Its pill had a wash, each of its tabs a
  half wash of its own, with the row's gap between them: several washes that
  read as several things. Where the folder ended and today's began was a
  guess.
- **The name went first.** The folder's pill had the same width as a tab, so
  it lost its name at the same moment the tabs did: an open folder was a
  mark with no word.

## The capsule

An open folder is **one wash** around its pill and its tabs. Its tabs are
**the first to give room**: the rest of the row keeps its width.

```
 shut   [▭ Work 3] [Figma      ] [Linear     ] │ [Notion     ] [Gmail      ]
 open   (▭ Work [Docs  ] [Specs ] [Figma ])    [Linear     ] │ [Notion     ] ...
        └────────── one wash, one rounded shape ──────────┘
```

- **One shape.** A single rounded rectangle (`Radius.control`,
  `Palette.wash(on:)`) from the folder pill's leading edge to the trailing
  edge of its last tab shown, drawn behind them. The folder pill has no wash
  of its own while open, and its tabs have none (`FolderPillPlace` no longer
  draws one on top).
- **Inside, the tabs are tabs.** The tab you're on keeps its own surface, a
  lighter pill on the wash. Hover, the cross, playing sound, a pair joined,
  all as anywhere else.
- **The pill hugs its name while open.** Shut, it is a tab's width as
  before, with the count. Open, it is as wide as its mark, its name and its
  insets, never wider than a tab, and the count is gone: the tabs are there
  to count. That change of width, on the same clock as the tabs coming out,
  is what says "open" (P1 in family-values-motion: the size change is the
  signal).
- **At icon-only widths**, a shut folder keeps its folder mark and the first
  letter of its name. Resting on its pill opens the same delayed hover card
  as a tab: full name, count, and up to six tab titles with their marks, then
  "N more". The card uses the existing light and dark glance surface.
- **Shut with a tab shown.** The tab you're on in a shut folder, or an
  agent's tab asking, stays out next to the pill, as it does now. It's inside
  the capsule: the wash takes the pill and that one tab. So wherever a folder's
  tab shows, it shows inside its folder.
- **An empty folder open:** the wash
  behind its pill alone, as an open folder's.
- **An agent's folder open, holding some back:** the "N more" pill is inside
  the capsule, the last thing in it.

Nothing else changes: pins, the stroke after the kept, the plus, the doors.

## Widths

Two widths instead of one: `outer` for loose tabs and shut folders' pills,
`inner` for a tab shown inside a folder. They're worked out by
`StripWidths.solve`, a pure function of the room, the pins, how many outer
and inner there are, the folder pills hugging their names, the stroke, and
any extra room for a tab being edited.

The row gives ground in this order, each step only once the one before it is
spent:

1. Everything at `Metrics.tabWidth` (186) if it fits.
2. **Inner** down to `Metrics.tabTitled` (80): the folder's tabs keep their titles.
3. **Outer** down to `tabTitled`.
4. **Inner** down to `Metrics.tabMinWidth` (36): the folder's tabs show their marks alone.
5. **Outer** down to `tabMinWidth`.
6. Past that, the run scrolls, as now, keeping the tab you're on in view.

So opening a folder in a row with room left changes nothing outside it but
where the tabs after it stand. In a full row, the folder's own tabs give room
first, then everyone gives it evenly. Several folders open share one `inner`.

The tab you're on inside a folder is at least `tabTitled` wide once inner goes
below it (steps 4 to 6), so its title stays, and the rest of inner shares
what is left. It's the one tab whose name you need.

The widths hold still under a drag, as the one width did: worked out as the
row stood when the hand took the tab, and let go again when it lands.

## Motion

Opening and shutting are already on `Folders.clock(opening:)`; everything
in this move goes on it, so the whole row moves as one.

| What | Opening | Shutting |
| --- | --- | --- |
| The capsule's trailing edge | grows, 0.22 s, curve (0.2, 0.8, 0.2, 1) | 0.14 s ease out |
| The pill's width (tab ⇄ its name) and the count | same clock, the count fades out | same clock, the count fades in |
| The folder's tabs | unfold from the pill's end, faded in, 30 ms apart, as now | fade in 0.1 s and fold, together |
| The tabs after the folder | slide by on the same clock, **same width** | slide back |
| Outer width, only when the row is full (step 3 or 5) | same clock | same clock |
| Folder mark | opens and shuts on CA's clock, as now | as now |

- **State at once**, geometry animated (P6): picking a tab inside, hovering,
  the wash turning on when a tab is held over a shut folder: no animation.
- **Exits faster** than entrances (the table above).
- **Reduce motion:** everything lands at once.
- **Nothing else moves:** no overshoot, no travel from elsewhere. It is the
  row you look at all day (P10).

## Clicks and keys

- A click on the pill opens or shuts the folder at once.
- A second click inside the Mac's double-click time shuts it back and
  names it (`Folders.tap`), as now.
- Hovering the pill of an open folder darkens the pill's own stretch of the
  capsule (`Palette.hover` over the wash), so the pill still reads as the
  thing to click.
- The right-click menus are unchanged.

## Dragging

The capsule is where a tab goes in or comes out, so it's drawn as the plan
has it, not as the row stood:

- **Held between an open folder's tabs:** the capsule stretches to take the
  gap, so the held tab is visibly inside. Let go, it is in.
- **Held past the last tab, or before the pill:** the capsule closes up
  behind it; let go, it's out. The line is `Folders.landing` as today.
- **Held over a shut folder's pill:** the pill is washed (aimed, as now).
  After 0.6 s it springs open, and the capsule grows round the held tab.
- **A folder carried whole** by its pill: its capsule goes with it, drawn
  around its pill alone while its tabs are folded under it.
- **A tab carried out of a folder** keeps the inner width it had until it's
  let go. Then every width is worked out again on `Motion.settle`.

## Next space coming (StripComing)

A space sliding in has its folders drawn by `StripItem.items`, which already
lists a folder's pill and its shown tabs. It takes the same two widths from
`StripWidths.solve`, and a capsule behind each folder shown open, so the
row doesn't change shape as the space lands.

## Checks

- `StripWidthsTests`: every step of the order above, one folder and several,
  the tab you're on held at `tabTitled`, a folder opening in a row with room
  (nothing outside changes width), one in a full row (inner gives first),
  the sum never past the room until it scrolls.
- In a probe world, light and dark, shut and open, empty open, a folder
  with the tab you're on while shut, an agent's folder with "N more", 40
  tabs with a folder of 6 open, compact folder hover cards, and drags into,
  out of and across a capsule.
  Screens go in `docs/shots/<date>/strip-folders/`.
- The glass: the wash is judged on a real screen on adhd, not from
  screenshots.
- `./design-check` on every line.

## Review on adhd, 2026-09-26

The isolated `evals/strip-folders-review.py` world captured [light open](shots/2026-09-26/strip-folders/light-open.png),
[dark compact and its hover card](shots/2026-09-26/strip-folders/dark-hover.png),
[40 tabs](shots/2026-09-26/strip-folders/dark-40-tabs.png), and
[an agent folder with 2 more](shots/2026-09-26/strip-folders/agent-more.png).
The other states and raw timings are in [the same directory](shots/2026-09-26/strip-folders/).

The last run checked the visible tab frames: 41 in the crowded row and 11
with the agent folder, with no adjacent frames overlapping. The active tab
kept 80 points in the crowded row. The title's canvas now clips before its
trailing action, including the agent face seen in the review photo. The
"N more" action keeps a small fixed width so its label remains legible.

For eight tabs, opening used 157–158 ms of main-thread CPU in a 0.8 s sample.
For 40 tabs, opening used 137–150 ms; the strip body ran at most twice,
the six shown folder tabs once each, and no outer tab body ran. Page size
did not change. The four crowded opening samples had no dropped frames;
closing had zero or one. One small dark closing sample lost three frames,
so these timings are evidence of bounded work, not a claim that every frame
is guaranteed. Idle main-thread CPU was 0.04% in a 2.2 s sample.
