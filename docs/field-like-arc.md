# The field like Arc: Open Tabs and Actions as a page

Status: plan, not built. Asked by balaji S (beta, moving from Arc): "I need
minimal like arc" for ⌘T and ⌘N. Decided on 2026-10-20: no second field; one
setting, and ⌘K's actions become a page of the field.

Measurements, Arc frame by frame with a scrubber, our field before and after
with playback and slow motion, every state, the Settings row:
https://claude.ai/artifact/7WPQrUZuq31bu2YVXrNfeH

## What Arc does (measured)

Sources: balaji's screen recording (Retina, dark) and two farm films of Arc on
m4 (main's profile, 1x, light, ScreenCaptureKit at ~60 fps, keys posted to Arc).

- Bar 766 × 328 pt with five rows; its height follows the rows. Centered on the
  window, top at 35% of the window's height. Radius 12, 1 pt gray outline.
- Input row 63 pt, text about 18 pt, "Search or Enter URL...".
- Rows 46 pt on a 50 pt pitch, radius 6, 9 pt from the bar's edge.
- The selected row is filled with the space's color (#275E71 teal for balaji,
  #8F95FF on m4), white semibold text. Every tab row says "Switch to Tab" with
  an arrow plate; dim on the others.
- Empty ⌘T: 3 or 4 most recently used tabs, the tab in front left out, then one
  row of Arc's own ("Contact the Team"). Recency order, not column order. No
  headers.
- No motion for the common paths. ⌘T: the whole bar in one frame, 57 ms after
  the key (165 ms the first time after launch), no fade, no scale. Esc: one
  frame, 41-47 ms. ↓ ↑: one frame, 23-26 ms, the selection jumps. Typing: the
  list is replaced in 1-3 frames, 25-90 ms. ⌘L: the same bar in the same place,
  the address selected, 2 frames (54 and 88 ms).
- Actions: Tab on the empty field enters it (⌘K, ">" and "/" do not). An
  "Actions" pill in the space's color sits in the input row, placeholder
  "Search...". Pill at +38 ms, list and a tint of the bar at +17 ms (balaji) to
  +155 ms (m4), in one frame. The bar squeezes to 0.989-0.994 and back in
  150-183 ms; an outer glow in the space's color grows over ~240 ms. Keys on
  plates at the right of each action (⌘W, ⌘D, ⌘R, ⌥⌘I).
- Leaving Actions: Esc, or ⌫ in the empty search, brings the list back in one
  frame at 46-56 ms, the glow gone at once, then the same squeeze (~0.995,
  ~160 ms). A second Esc closes the bar in one frame (52 ms).

## Yab today (from the code)

750 × 475 always (Metrics.fieldWidth, Omnibox.swift:56, 67), radius 26
(Radius.box), rows 38 with radius 10 and an ink 0.08 veil. The empty field
shows Now, Favorites, Recent Tabs, Frequent, Quick Actions, 8 rows at most
(FieldPlaces.swift:819-923); tab rows say "Open Tab" (Omnibox.swift:790, 819).
It opens with opacity over Motion.arrive, 0.22 s (App.swift:1386-1388), and
closes in one frame. ⌘K raises a 350 pt panel over the foot (FieldActionsPanel,
FieldViews.swift:861-1072), opacity in 0.22 s, out 0.15 s.

## The change

### Settings › Search: Empty Field Shows

- `Prefs.swift`: `field.empty` = `sections` | `openTabs`, default `sections`.
- `SearchSettings.swift`: a row "Empty Field Shows", "What ⌘T and ⌘N show
  before you type.", chosen by picture like Look (SettingsCorePages.swift:284):
  Sections, Open Tabs. Keywords: empty, new tab, arc, minimal.

### Open Tabs

- `FieldPlaces.swift:819-923`: with `openTabs`, the empty ⌘T and ⌘N list the
  space's tabs by last use, the one in front left out, at most 5, no section
  headers.
- `Omnibox.swift:790, 819`: "Switch to Tab" at the right of each tab row, ↩ on
  the selected one. `Omnibox.swift:884`: the selected row in the space's color
  with white text.
- Typing, ⌘L and the box's size, radius and place stay as they are in both
  modes. FieldFoot is not touched: About and Invite a Friend at the left, the
  action with ↩ and Actions ⌘K at the right.

### Arc's timing where we have the same motion

- `App.swift:1386-1388`: `fieldMotion` without Motion.arrive, so the field is
  there in the next frame, in both modes. Closing is already one frame; arrows
  and typing already have no motion.

### Actions as a page of the field

- `FieldActionsPanel` becomes a page of the field, like a place: the actions in
  the main list, the input row "Search actions…".
- FieldFoot at the left: the place capsule "‹ Actions" with the subject (the
  row it acts on) in gray; a press goes back, as for places.
- `Keymap.swift:853`: ⌘K as now, and Tab on the empty field (Tab does nothing
  there today; in a typed field it stays site search).
- Keys from Keymap on KeyGlyphs plates at the right of each action; ↩ on the
  first.
- In and out (Esc, or ⌫ in the empty search): the list is replaced in one frame
  and the box squeezes to 0.99 and back in 165 ms, ease-in-out, as Arc does both
  ways. Arc's tint and glow are not taken: the name at the bottom left already
  says where you are. A second Esc closes the field.

## Checks

- `evals/field-compare/compare.py`: add Tab → Actions and the way out; Arc and
  Yab on one farm Mac, frames and ms in the report. Targets: open in 1 frame,
  Actions in 1 frame plus the squeeze.
- Unit tests Field* and OmniboxAddress, and a new one for Open Tabs' order
  (recent first, the tab in front left out, 5 rows).
- A profile like balaji's (from Arc, many tabs): ⌘T with Open Tabs, ↓, ↩ switches
  the tab; ⌘K and Tab, Esc; light and dark.
- Before handing over: a winshot of every state beside the artifact.
