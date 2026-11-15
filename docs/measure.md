# Measure

Measure puts rulers and draggable guides over a development page, and measures what is on it. Open it with the ruler in the page band, `⌥⌘U`, `⌥⌘C` (Chrome's Inspect Element key), or Measure in the page's right-click menu, which opens it with the right-clicked element already picked. The Measure menu item uses the existing ruler icon and appears immediately after Inspect Element when Developer Mode is on and the Developer Tools card is closed. Inspect Element in that menu always opens Yab's Elements on the right-clicked element. While the Developer Tools card is out, `⌥⌘C` is WebKit's picker in the card instead (see docs/developer-mode.md).

Code: `Measure.swift` (the page's drawing, in yab's own script world, in a closed shadow root in the top layer), `MeasureDock.swift` (the dock at the page's foot). The design, its states and the research behind it: work/design/measure-2026-10-09 (artifact VzEwuZSbZiKvwJY5mufo5j).

## What shows, and when

Nothing comes by itself. Each thing comes when asked and goes the same way:

| What | Comes | Goes |
| --- | --- | --- |
| An outline and the box's name and size | under the pointer | the pointer leaves |
| The picked box's fills and numbers | a click | `Escape`, or a click on another box |
| Red distances | while `⌥` is held | `⌥` let go |
| A kept measurement | `⌥S` | `⌫` with nothing picked, or × and Clear in the sheet |
| The dock | Measure on | Measure off |
| The sheet: numbers, rules, motion, kept, notes | `Space` or Details | `Space`; it stays as it was left |
| The page's troubles, drawn | a click on "3 issues" | a second click |
| A note's field | `N` | `↩` adds it, `Escape` drops it |
| Copied | `⌘C` or Copy for Agent, on the button | after 1.5 s |
| A padding or gap handle | the pointer near it, on the picked box | the pointer leaves |
| Every box at once | `X` | `X` |
| A picture of the design | dropped on the page | `Escape` (after the selection), or × |

## On the page

- **Picked**, a box's numbers stand in the bands they measure: padding in the middle of its band (accent), margin outside a quarter along (orange), one number for the gaps between rows and one for those between columns of a flex or grid, on a hatch. An edge its letters come closer than 4 to gets a red bar on the edge and its number past it, 0 too: what an eye sees as "text right at the edge". Letters are measured as drawn (the font's ascent and descent, not the line's box). Small boxes (under 90 × 44) keep only their tag.
- **The tag** says the box's name and size, and what matters for its kind: text its size/line height and weight, color and contrast (AA, AAA, or the ratio); a box its corner and ground. It stands above or below, wherever it covers fewer letters. The picked box keeps its tag while another is under the pointer.
- **No number lands on another**: it steps past what it hits along its own line, then off it.
- **`⌥`** measures from the picked box to the one under the pointer (red lines; 0 as a bar on the touching edge). Over the picked box itself it shows what is inside: every space from its edges to what it holds and between neighbours, or, for text, its lines, leading hatched, the baseline, cap and x heights and the step between lines. With nothing picked, from the box under the pointer to its parent, the parent outlined faintly.
- **`⌥S`** keeps the measurement shown (by its key, not its letter: `⌥S` types ß on a Mac). Kept ones are measured again every frame, so they live through scrolling and edits; each number has a white dot. A live measurement already kept isn't drawn twice.
- **Guides**: drag from a ruler; they snap to the edges and middles of what is under them, the trackpad ticking once as each catches; `⇧` snaps to the 8-point grid; drag one back to its ruler to drop it. Kept per server and path across reloads. The rulers' corner opens a menu: Columns, 8-Point Grid, Pixels, Rems, Clear Guides.
- **Keys** with a box picked: `⇧↩` parent, `↩` child, `⇥` next sibling, `⇧⇥` previous. `Escape` first lets go, then takes the design's picture away, then closes Measure.
- **Handles**: on the picked box, near the inside edge of its padding or in a gap, a handle shows; dragged, the value changes in the page's own rule by 4 (`⇧` by 1, `⌥` both sides), the trackpad ticking at each step. Not saved to a file: it goes to the agent with Copy for Agent.
- **`X`** draws every box of the page at once, colored by depth, padding tinted, over which Measure works as usual.
- **A picture of the design** (a PNG from Figma, an artifact) dropped on the page lies over it in Difference: what matches goes black, what is off glows. Arrows move it by 1, `⇧` by 10; `D` toggles Difference and a faded 50%. A 2x export is drawn at half.
- **What moves**: the picked box's animations (CSS animations, transitions, Web Animations, in it and under it) are in the sheet; `,` and `.` step them a frame (1/60 s) back and on.

## The dock

The agent's dock (AgentDock.swift) in every part: the `HUD.plate` on Liquid Glass, light over a dark page and dark otherwise (`HUD.surface(over:)`, by the page's `Tab.under`), 36 high, a regular button 4 in, its corner 8 + 4 = 12, 14 off the page's foot, the ruler where the agent has its face. With an agent's dock on the same page, Measure's stands 8 above it.

- **Words**: with nothing picked "Click a box, hold ⌥ to measure"; picked, its name and size; with a design's picture and nothing picked, the picture and how far it was moved. At least 260 wide, so a click on a short name doesn't move the dock. The words cross over (out 6 up in 0.1 s, in from 6 below on `Motion.morph`), the width follows on `Motion.reshape`, the buttons keep their end.
- **Buttons**, all `.yab(…, .regular, surface:)` on the plate's own surface: the troubles as a word ("3 issues", quiet until shown), Details `space`, Copy for Agent `⌘C`, which says Copied in its own width for 1.5 s. With a design's picture, Difference `D` and ×.
- **The sheet** (Space): the dock grows up into a card, as the agent's answer does (`CardFrame`): everything 12 in, the corner 8 + 12 = 20, all on `Motion.reshape`, the bottom staying put. Left, the numbers: position, padding (0 in red on a box the eye sees), to the letters (the near edges in red), gap, margin, radius, type, color on its ground, the trouble. Right: what moves (its curve with a dot where it is now, what it changes, a scrubber, Replay at 1×, ¼×, ⅒×, the frame), the rules (the winning one first, three at most, each with its file and line; a beaten declaration struck through; a value clicked is a field: `↩` keeps it in the page's rule), the page's troubles when shown (a row picks its box; hovering it lights the box), kept measurements, notes, Open in Elements, and the keys.
- **`N`**: the words become a field, "What should change in section.tile"; `↩` adds the note (a violet number on the box), `Escape` drops it.

## The troubles

Looked over 0.8 s after the page changes, at most that often, and on Measure coming; 3000 elements at most. Each is said in words:

- **Text at the edge**: a box the eye sees (a ground, a border or a shadow) whose letters stand closer than 4 to an edge.
- **Spills out**: letters past a box's edge without an overflow to hold them.
- **Cut off**: `overflow: hidden` hiding words, unless it ends in an ellipsis.
- **Low contrast**: under WCAG AA for its size (4.5, or 3 from 24 px, or 18.66 px bold), against the first ground under it.
- **Scrolls sideways**: the outermost box that makes the page wider than its window.

Spacing off a 4 or 8 scale isn't one: on most pages it is intended, and it would be noise.

## Copy for Agent

`⌘C` with a box picked, or the dock's button: the box's selector, text, size and position, box (padding, gap, margin, radius), type and colors, its text inset, the distance to the box under the pointer, its motion, the troubles in it, every value changed by hand with its rule, file and line, old and new, the kept measurements and the notes. No notice: the button says Copied.

## Testing

The native end-to-end check is `python3 evals/devmode/measure_check.py WORLD URL [OUT]`. `WORLD` is an isolated `YAB_PROBE` world with its bench enabled, and `URL` normally serves `evals/devmode/measure.html` from a server already running on this Mac. If an existing local server serves a different page, add `--inject-fixture`; the check writes the same fixture into that page and restores it after reload. The check does not start a server. It drives the page with `window.__yabMeasure.bench({...})` in the yab world, the dock with the bench's `measureact` and `measuredetails`, and reads the dock back from the probe's `dev.measureDock`.

`MeasureTests` runs the arithmetic (`Measure.math`) in JavaScriptCore, parses the whole page script, and decodes what the page tells the dock.

`PageInspectMenuTests` checks the separate Inspect Element and Measure menu items, their order and icons, clicked-point conversion, native action forwarding, and Developer Mode/card visibility. `MenuCommandCatalogTests` checks the existing Measure Page/Hide Rulers actions in field search and Actions, including both states and remapped shortcuts. The field keeps its existing page-level actions; the right-clicked target is specific to the context menu. The existing `⌥⌘C` and View menu routing is unchanged.
