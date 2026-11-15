# Port and agent in the tab list

Implemented design for yab's Developer Mode. [Visual mockup](../work/visualizations/yab-tab-port-agent.html).

## Decision

Keep one quiet trailing metadata lane, followed by the existing 15 pt face lane. On a local tab being used by an agent, the order is **site mark · title · `:port` · agent face**. A script uses the existing square robot face in the same place. The port remains plain monospaced text, never a colored badge. The face remains the only animated element and keeps its existing action and handoff expressions.

On hover, the close button replaces the port inside the metadata lane. The face stays in place, so asking what the agent is doing cannot become an accidental close. On a port-only tab, the close button replaces the port in the final lane. The port returns when the pointer leaves. The address field continues to show the host and port while the tab is hovered.

```text
Sidebar, at rest      ◉  Inventory preview         :3000   ◉
Sidebar, hover        ◉  Inventory preview            ×    ◉
Script, at rest       ◉  Build output              :5173   ▣
Script, hover         ◉  Build output                 ×    ▣
Port only, at rest    ◉  Local dashboard           :8080
Port only, hover      ◉  Local dashboard              ×
Agent only, at rest   ◉  Research notes                   ◉
Agent only, hover     ◉  Research notes              ×    ◉
```

The diagram uses generic marks; the product keeps its current site favicon, circular agent face, and square script robot. The port is part of the tab identity, while the face describes who currently has access to it. Neither replaces the favicon in a titled row.

## Geometry and priority

| Surface | Layout rule |
| --- | --- |
| Sidebar 189–475 pt | Keep the existing 28 pt row. Site mark and face are 15 pt. Put the port in a trailing lane wide enough for `:65535` (about 40 pt at 11 pt monospaced), with 6–8 pt of air from the title and face. The title alone flexes and fades. |
| Titled top tab | Same order and 28 pt height. When available title space would fall below about 56 pt, hide the port; preserve the face and title. There is no width to add a badge. |
| Compact top tab below 80 pt / pinned tab | Keep the current single face or site mark. The port remains in the address field, never squeezed into the compact icon. |
| No agent | The port and close control share the final lane. No blank agent lane is reserved. A parked tab without a close control keeps its port visible on hover. |
| Agent or script | Reserve the face lane and the port-or-cross lane. A 20 pt close hit target is kept to the left of the face. Neither lane moves when hover changes. |

The port lane should size to the widest valid port, so switching between `:80`, `:3000`, and `:65535` does not move the face. A fixed lane also prevents the hover cross from causing title relayout. No new per-frame geometry reads or timers are needed.

## States to preserve

- **Agent and script:** Keep the current face shape and expressions, including waiting for the user, failure, loading, and completion. Do not add a second activity ring or a label saying “agent.”
- **Audio and camera indicators:** Existing safety and media controls take priority over the port. If a row cannot fit title, port, face, and a media control with a usable title, hide the port. Never hide the face or an active media control to keep the port.
- **Pending call ending soon:** Keep that indicator ahead of the trailing lane; under space pressure hide the port before reducing the title to nothing.
- **Private tab:** The port may be shown for a local page, but the existing private mark stays in its current place. No extra color.
- **Accessibility:** The face keeps its agent or script name and action. The visible port has the accessibility label “Local port 3000”; the close control remains “Close tab.” When the port is hidden in a narrow top tab, the address field still exposes it.
- **Motion:** Cross and port exchange with a short opacity transition; the port does not slide. Respect Reduce Motion. The face's own animation continues unchanged.

## Why this fits the current code

`SideRow` and `TabPill.titled` place `DevPort` after `FadingTitle`, while `TabEnd` overlays the trailing slot. The old 16 pt padding on `DevPort` let the agent's hover cross overlap the port. The implementation now reserves one fixed port-or-cross lane and the existing final status lane, and removes the title's redundant overlay clearance when the port lane is present. The visual mockup remains schematic; the SwiftUI layout is implemented in `DevMode.swift`, `Side.swift`, and `TabBar.swift`.

## Acceptance cases for implementation

1. Sidebar at 189, 232, and 475 pt with 2-, 4-, and 5-digit ports; long Latin and Cyrillic titles; agent, script, and no worker.
2. Hover the row, the face, and the cross separately. The face never changes position, and the close hit target never overlaps it.
3. Top tabs at 186, about 140, and below 80 pt; pinned tab; changing width live without text jumping.
4. Agent idle, navigating, waiting for a handoff, failed, and finished; script doing the same where applicable.
5. Port plus audio, loading, private mode, and `EndingSoon`; compare both light and dark appearance and Reduce Motion.

## Verification, 2026-09-26

- `./adhd build` built `yab Dev.app` successfully with the new layout.
- The layout budget leaves 76 pt for the title at the 189 pt sidebar minimum and 60 pt at the 168 pt top-tab port threshold, with a 5-digit port and agent face.
- `./adhd sh 'swift test --skip-build --filter DevModeTests'`: 7 passed.
- `./adhd check`: `evals/browse/check` passed 19/19. The whole gate is red due to `AgentHoldTests.testAFrameWatchedWhileItLoadsAnew` at line 273 (`raced` was false); the same test failed again in isolation. `design-check` reports pre-existing violations in the concurrently edited `SelectionList.swift`. Neither failure involves the port layout files.
- Native visual interaction was not captured. The mockup demonstrates the geometry; the exact running-bundle hover and narrow-width states still need hands-on acceptance.
