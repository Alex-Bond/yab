# Column corners

Every corner in the column follows one rule: a shape inside another takes
the outer radius less the inset between them, and shapes stacked at the same
edge share a curve. The reference to check against is a live prototype of the
whole column drawn from the code's constants, 1 px = 1 pt:
[sidebar-corners/prototype.html](sidebar-corners/prototype.html), published at
https://claude.ai/artifact/V9VbECv8yvcHSLGfnyktY1. It switches look, density,
docked / put away / brought out over the page, the player, update, downloads,
folders, a split pair, a pin being dragged or edited, three or nine spaces;
zooms to 8×, labels each radius against the one the rule asks for, and can
show the column before the 2026-10-13 fixes.

| Shape | Corner (Comfortable / Compact) | Why |
|---|---|---|
| Window, the column's outer corners (docked or brought out) | the window's own | not cut by the column: flush with the window's edge, the window server rounds them; a SwiftUI cut there never agrees with it and showed what lay under the column (#221 docked, register 368 brought out over a white page) |
| Page beside the column | 10 | 18 less the 8 inset |
| Tab rows, folders, New Tab, space name row, drag placeholder and sheets | 10 / 8 | `SideBar.radius` (`Density.radius`) |
| Address plate and pins | 10 / 8 | `SideBar.corner(side)`: the row's, scaled down only for a pin shorter than the plate |
| Header doors (back, forward, reload) | 10 / 8 | reload is flush with the plate; 8 in from the brought-out card's 18 |
| Plate's doors | 6 / 4 | plate less 4 |
| Row cross square, space ••• | 24 / 20 square, 4 | `RowPlate.column` |
| Pair chips | 7 / 5 | pair row less 3 |
| Foot: downloads, spaces, plus, Update, Mail | 10 / 8 | 8 in from the window's 18, under rows at 10; 8 in the strip |
| Player island | 15, 3 in | 18 less 15 (`Band.edge`) |
| Brought-out column card, inner corners | 18 | the window's radius (`Metrics.floatCorner`): flush with the window's edge since 2026-10-14 (`Metrics.floatInset` 0), so window, card, island and doors all share curves. At Arc's 3 inset it needed 15, and the island and doors inside it would have had to shrink |

Fixed on 2026-10-13: d624e437, 2662d3a3, 99ad2232, 715bc429, 59bf15cd.
`evals/sidebar-corners/shoot.py` pictures the built column in the same
states for comparing with the prototype.
