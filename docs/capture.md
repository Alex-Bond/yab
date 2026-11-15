# Capture

⇧⌘2 takes a part of the page, the page as it shows, or all of it, frames it
on a backdrop and puts it on the clipboard. Arc's Portrait Mode is the
starting point (one control, a hue, and the picture is the page, not the
browser); Yab takes it out of developer tools and lets the page's own
structure decide the edges. Code: `Capture.swift` (the capture, the
picture, the clipboard, saving), `CaptureView.swift` (everything on
screen).

## How it goes

- **In.** ⇧⌘2, File › Capture…, "capture" in ⌘T or the camera in the
  address band. The page dims a little and a glass bar at its foot says what to
  do: click a part or drag an area, ↩ for what shows, F for the whole page,
  esc to leave. ⇧⌘2 again takes what shows.
- **A picture.** Capture Image in a picture's right-click menu takes that
  picture at once: nothing to pick, no dim, no backdrop. It uses the file's
  own pixels (an SVG, or a picture its site won't give again, comes off the
  page where it shows), the first frame of an animation, and keeps the
  file's name, as a PNG. A look given it in the editor stays with it and is
  not the next capture's. From a private tab nothing stays in the
  clipboard's history or in Files. Capture… in a page's right-click menu is
  the way in for anyone who doesn't know the key.
- **Picking.** Under the pointer the box the page itself draws there is
  outlined, with its name and size in points ("Section 1216 × 356"): an
  image, a card, a form, a heading. ↑ takes the box around it, ↓ goes back
  in. The wheel still scrolls the page. The outline, the dim and the bar
  are Yab's own layers over the page and never in the picture.
- **Taken.** The Mac's own shutter plays (only when Sound › Play user
  interface sound effects is on), the picture is on the clipboard at once,
  and it lifts off where it was and goes to the page's top right corner,
  the card growing out of it: the backdrop out of the picture, the card out
  of the backdrop, "Copied" and the size in pixels last. It stays six
  seconds, longer while the pointer is on it; esc or a click elsewhere
  puts it away.
- **The card.** Drag the picture anywhere (Finder, Slack, Figma) for a
  file; click it, or Edit, for the editor; Save, or ⌘S, for Downloads. The
  card also follows a two-finger swipe left or right to dismiss; a short
  or cancelled swipe returns it to its corner. Vertical scrolling and
  swipes in the editor do not dismiss it. The preview's corner is the
  card's less its inset, whatever the picture's
  scale, so it sits in the card as every other card's contents do.
- **The editor** is the same card grown over the page, the page blurred
  behind it. Save is one button in both: it rides the card's corner into
  its place beside Done and back; Copied and Edit go at once, and every
  word in the editor hangs from the card's edge, coming as it settles, so
  none is ever past it: the backdrop (the page's own colors, any hue on a rainbow, the
  wallpaper, none), the shape (Auto, 16:9, 1:1, 4:5), and whether emails,
  keys and card numbers are hidden. A change shows at once and is on the
  clipboard 0.15 s after the last one. Done, ↩ or esc, and it goes back
  into the corner the way it came.
- **Save** writes a PNG into the downloads folder, named as the Mac names
  its screenshots ("linework.studio 2026-09-27 at 9.29.12.png"), and the
  picture flies into the downloads button, which ticks. No notice: the
  button already says it. Where the button can't be seen, a notice says
  "Saved to Downloads".
- The look chosen is kept for the next capture (Pika's way): no presets.

## What is in the picture

- WebKit's own picture of the page (`takeSnapshot`, painted in the page's
  process): no permission to record the screen is needed, and nothing of
  Yab's is in it.
- Long pages and tall selections are assembled from screen snapshots at the
  existing viewport size, avoiding PDF export's different painting of filters,
  masks and composited layers. Fixed overlays appear once; sticky elements
  are captured at their document positions. Scrolling and temporary styles
  are restored on completion, cancellation and failure. Each tile checks for
  private data, including content created on scroll. Infinite lists are
  limited to the length measured when capture starts, with a maximum of 512
  viewport tiles. Past 36 million pixels (a page about 11,000 points long at
  2x) the output is scaled down.
- **Private things** are found in the page, not guessed from pixels:
  password, email, phone and card fields, autofilled fields, and text that
  reads as an email, a card number, a Stripe, GitHub or AWS key, a JWT or a
  long hex token. They are painted over solid (a blur can be undone), in
  the file and in the preview alike. On by default.
- The backdrop "Page" is the picture's own edge color, lifted into a soft
  diagonal; near white it is a quiet warm gray so the picture's edge and
  shadow still read.
- The PNG says its pixels per inch (144 at 2x), so it pastes at the page's
  size, and carries the page's address and title.
- No watermark.

## Why it is built this way

- All motion is Core Animation in one view over the window (the way
  LinkPeek and the downloads' flights are): a SwiftUI animation is a
  commit of the whole window per frame, which on a loaded Mac stalls for
  hundreds of milliseconds. SwiftUI only draws the bar, the row and the
  editor's controls, in hosting views that only fade.
- The preview is the file: one layout (`CaptureLayout`) draws both, and
  the preview is the canvas scaled, so nothing jumps when the picture
  lands or changes shape.
- The PNG is made away from the main thread and put on the clipboard
  when it is ready (compose + PNG below, 40 to 300 ms; the card is still
  landing), about 1 ms on main. It is not a promise: a clipboard history
  (Raycast's, Universal Clipboard) reads a new clipboard at once, and a
  promise made the main thread wait out the PNG for it: 40 to 140 ms on a
  change of shape, 120 to 300 ms landing a whole page, the "frame Core
  Animation holds" these notes once blamed. Something copied meanwhile is
  left alone; a newer look replaces an older one. Yab's own clipboard
  history is handed the same PNG.
- The web view is never resized, scrolled or restyled for a capture.

## Testing

`./bench` drives it (`grab start|hover|take|edit|back|save|close|style|paste|state`)
and `./bench pace capture-start|capture-box|capture-visible|capture-whole|capture-edit|capture-back|capture-shape|capture-save|capture-close`
times each beat frame by frame. `work/capmeas/meas.py` runs the whole
path on a probe world and writes the numbers below.

On adhd (M-series, a 2328 pt wide page at 2x, median of 8 runs, 4 for the
whole page, 2026-09-27):

| | part | what shows | whole page |
|---|---|---|---|
| snapshot | 18 ms | 28 ms | 26 ms |
| picture ready to land | 38 ms | 63 ms | 78 ms |
| compose, off main | 12 ms | 40 ms | 110 ms |
| PNG, off main | 27 ms | 107 ms | 186 ms |
| writing the clipboard, main | 1 ms | 1 ms | 1 ms |
| paste read by an app | 1.1 ms | 1.1 ms | 0.5 ms |

Every beat (start, box, edit, shape, back, close) runs at 16.7 ms frames
with at most one dropped; main-thread CPU for a whole-page capture went
from 159 ms to 77 ms once the history stopped reading the promise.

With Raycast's clipboard history running (adhd, 16 interleaved runs of
each build, load 3 to 6, whole-module builds, 2026-09-27), dropping the
promise:

| main thread's longest pass | promise | PNG when ready |
|---|---|---|
| landing a whole page, median | 163 ms | 17.5 ms |
| landing a whole page, passes over 34 ms | 12 of 16 | 0 of 16 |
| a change of shape, passes over 34 ms | 6 of 32 | 0 of 32 |

Main-thread and process CPU and WindowServer CPU are the same within
noise for every beat. Idle after a capture: 0.04% main-thread CPU, 4
wakes a second.
