# The island: what plays in other tabs

When a tab you aren't on plays something, Yab shows it under the column's
foot, at the window's bottom corner, as an island of Liquid Glass. Code: `Tune.swift` (what a tab plays, and
`Player`, which tab is the island and which are buds) and
`PlayerBand.swift` (the island itself). Tests drive it with `./bench band`.

## What it does

- **At rest** a capsule a tab row tall: the cover (round), the title, the
  artist, and four bars in the cover's color that move while it plays and
  lie down as dots when it pauses. The glass is tinted with the cover's
  color, faintly.
- **Under the pointer**, after 0.12 s (passing over it on the way to the
  foot opens nothing), it opens upward into a card on the same glass, over
  the foot (the extensions, the space) rather than pushing it up, and at
  least 224 points wide (`Band.minCard`): in the usual 240-point column it
  is the island's width, 6 in from both of the column's sides; in a narrower one it stands out over the page, so its buttons never
  crowd. Narrow, the buttons share the room between the way back and the
  sound evenly (a door and 10 apart at 228, a door and 12 from 248). The
  cover grows from where it was to 48 points, the words take two lines, the
  progress line, the times and the buttons (previous, play or pause, next,
  the sound) come in a beat after the shape. It closes quicker, with no
  give, once the pointer has left the card and its rows (80 ms of grace for
  crossing a gap).
- **The buttons** are drawn as Apple Music and Control Center draw theirs:
  previous and next two filled triangles, play a filled triangle and pause
  two bars, a size up, their corners rounded by true arcs of 1.8
  points, as SF Symbols round theirs (the pause bars 1.6), a triangle grown
  about its middle by what the rounding takes off its tips so it keeps its
  size. At the left end the way back to the tab that
  plays is that site's own icon in its colors (its first letter on a plate
  without one), with Yab's tip "Show in YouTube Music"; at the right end the
  sound, quieter (55%). Under the pointer a round ground comes up, a
  press squeezes the mark to 84% and lets it go with a little give. Pause
  and play replace each other as Apple's symbols do, the old one down and
  out, the new one up with a little give; a skip moves its
  triangles, the back one into the front's place, the front one on and out,
  a new one growing at the back. Shape layers, on the render server. The
  progress line is a 5-point capsule.
- **15 seconds back and on** take the skips' places wherever there is a
  line to move along and the site gives no previous and next of its own
  (`Tune.seeks`): a video, a podcast, a live stream that keeps a stretch.
  A lone next, a video's autoplay, stays in the menu. They are the floating
  window's marks, an arrow round a 15 (`gobackward.arrow`, `skip.15`), the
  arrow turning 30° the way it points and back in 0.26 s; the line and the
  times go there at once, as a let-go seek does. At a live stream's edge
  the forward one is faint (30%) and does nothing. So the row never stands
  empty around play, and play never moves. The way back's tip sits over
  the line, not over the time gone under it.
- **Where it plays.** The times and the line go on from the page's last
  reading by the clock, round the length for media that loops (`loop`,
  `Tune.loops`), held at the end when a reading finds it sitting there.
  Opened, and every two seconds while open and playing, the card reads the
  page's own clock again, so a stream its script starts over, or a seek
  nobody announced, is shown where it is (`evals/player-pause/loop.py`).
- **Scrubbing.** The open card's progress line is a scrubber. A click on it
  (9 points above or below counts, `Band.grip`) goes there; pressed and
  dragged, the fill follows the finger and the times say the point under
  it, the page seeking roughly as it goes (`fastSeek`) and exactly where it
  is let go. Two fingers sideways over the card do the same, the line's end
  following them a point a point. A live stream's line is the stretch it
  keeps, its words saying how far behind the point is. The page's own
  media is moved (`TuneWatch.seeker`), as the floating window moves it; a
  player that keeps its media out of the page, as Spotify's does, by its
  own progress bar, only where the finger lets go.
- **A skip** slides the old face out the way it went and the new one in from
  the other side (P8). The same carousel swaps the island and a bud.
- **Pause** flips the state at once (P6): the bars fall to dots one after
  another, the title goes muted, the cover dims.
- **Play and pause at rest.** Paused, the island's end shows play in the
  bars' place (a size down, the title's muted ink), so a paused row says
  how it plays again; a press there plays it where it is, the tab in front
  kept, the island up. Under the pointer while it plays the end is pause
  on a round ground. That end opens nothing; the rest of the row opens the
  card after its beat, and a click on it goes to the tab, as Arc's does.
  Before this a paused row had no play: a click on it went to the tab, the
  island went down with it and the page beside the column became the
  playing tab's (Ganidhu, 2026-10-09; `evals/player-pause/check.py`).
- **Where it sits.** 3 points in from the window's side and from its
  bottom (`Band.edge`: the window's 18 less the capsule's 15, so the two
  curves share a center), the same both ways, as wide as the column less
  those 3 on each side; one whole capsule, its bottom corners 15 as its top
  ones. The column keeps 33 points under its foot for it (`Band.room`), so
  the foot stands right above the island. Every
  layout puts its glass back on its resting place, so a rise cut short
  can't leave it on the window's edge.
- **Opening and closing on either side.** The view is pinned to the
  column's outer side, so the card grows out of the row upward and, where
  it is wider than the row, toward the page: rightward with the column on
  the left, leftward with it on the right; never past the window's edge.
  It closes back the same way.
- **Coming and going**: up out of the column's bottom edge in 0.22 s,
  0.4 s after you leave the playing tab so ⌃Tab running past it doesn't
  flash it; down into it in 0.26 s, soft at both ends, the foot coming
  down over it on the same curve (`Band.sink`). Out in 0.15 s, gathering
  speed, the foot landed at full speed and read as a drop (2026-10-13).
  `evals/player-pause/room.py` films it, docked and floating, and checks
  the column's room goes with the island.

- **Its menu.** Right-click or Control-click it: Show Tab, Pause or Play,
  Next and Previous, Mute Tab, the others playing to swap in and Pause All.
  No Hide and no switch since 2026-10-13, as in Arc: it is there whenever
  something plays in a tab you aren't on (`showsPlayer` is no longer read).

## Live streams

A live stream has no length to count down from: where the time left would
be, the island says Live, or how far behind the edge it plays ("5m
behind"), and the time gone is left out. Its line is the stretch the
stream keeps, its right end live. The floating window does the same: the
words where the whole would be, a bar over the stretch it keeps, a click
at its end back to live, and no going past the edge. `LiveEdge.swift` has
how a stream is told apart and where its edge is; YouTube gives its live
videos a length an hour past the edge (feedback 35), so that length is
never used. `LiveEdgeTests` and `evals/live/check.py` cover it.

The words are the way back (variant A of the 2026-10-03 design):

- **Behind**, "45s behind", "5m behind" or "1h 12m behind" is a button to
  the edge, underlined in the floating window and in ink in the open
  island. **At the edge** it says Live and is not a button.
- **Dragging** the floating window's bar, a tip over the pointer says how
  far behind that point is ("32m behind", Live within 40 s of the edge);
  the words keep what they said until it is let go.
- **Paused**, the edge goes on: the count grows (in the island once a
  minute, never ticking seconds). +15 is dimmed and deaf at the edge, and
  wakes once behind.
- **An advert inside the stream**: "Ad · muted" where the title's second
  line is (the island's artist, the floating window's top), and the
  stream's own words stay as they were.
- **Fetching at the edge**: "Catching up…", and still Live: a stall is
  not a step back.
- **Broadcast over**: kept as a recording, it has a length again and
  counts down like a video; Live goes away.
- **Nothing to rewind** (a radio, an HLS window under 30 s): no bar, no
  steps of 15, only Live.

A live tab's island reads the page again every 15 s while it plays and
every minute while paused (`TuneWatch.followLive`); a video's never.
`evals/live/pictures.py` pictures every state, and `evals/live/sites.py`
drives real live sites.

## Several tabs playing

- **Every space.** A tab playing in a space you left still counts: the island
  stays as you go from space to space, and the way back goes to that space
  first, then to the tab.

- **Who is the island.** The one it shows stays: a tab that starts playing
  later goes into a bud and doesn't take the island, or every advert would
  move it. A lead paused for 3 s while another plays gives way to the newest
  one playing. A tap, a swipe or the island's tab closing change it.
  Going to the island's tab (its title, its cover, the way back, Show Tab,
  the tab picked in the column) takes the island down with it, and what
  else plays comes up 0.4 s later as an island of its own: never slid in
  under the pointer, which read as the click having swapped players.
  Media keys keep controlling the island's tab.
- **Buds.** The others are round buds of the same glass beside the island,
  the one that started last first. A second one peeks 4 points out from
  behind the first, and from two up a count sits on the bud's corner. A
  newcomer is born inside the island's right end and leaves it with a neck
  of glass; one that stops goes back into it.
- **Swapping.** A tap on a bud: its cover rides from the bud to the island's
  cover, the island's old face slides off left and drops, small first, into
  the bud. Two fingers sideways over the island at rest: the face follows
  them and the first bud's face slides in under the edge; let go past 40
  points, or quickly, and they swap, else it springs back. Such a swipe is
  the island's: the column's swipe between spaces leaves it alone. Open, or
  with no buds, the island's swipe scrubs instead (Scrubbing, above; at
  rest it opens the card at once); over the open card's rows, or with no
  line to scrub, the column has it.
- **Open with buds.** The buds grow into rows over the card, up to three,
  each its cover, title, artist and bars. A tap on a row swaps it in.

## Corners: concentric, as Apple asks of glass

- The island at rest is one capsule (radius 15 at 30 points tall), and
  it stands `Radius.window` (18) less 15, 3 points, in from the window's
  corner, so its bottom curve shares the window's center (`Band.edge`,
  `Band.foot`). Open, the card keeps
  that bottom and takes `Radius.card` on top. Per-edge corners are
  `NSView.cornerConfiguration` on macOS 27 (`IslandDrop`); its top and
  bottom are the flipped view's, so the code passes them swapped. Built
  with Xcode 26, as releases are (adhd), the SDK has no
  `cornerConfiguration` to override, yet macOS 27 asks for it by name, so
  `IslandDrop` answers by that name with a configuration made through the
  runtime (`IslandGlass.corners`); 0.0.9, built without it, had the top's
  20 all round. On macOS 26 the glass has one radius, the capsule's, set when
  the glass is made: its edges start at the capsule's, so their change
  never came and the glass kept its own 6 (seen on 26.7, 2026-10-13). The cover is round,
  4 points in, so its curve has the capsule's center.
- A bud is a circle; its cover a circle 3 points in.
- Open, the island is a card: `Radius.card`, which is `CardFrame.inset`
  (12) plus `Radius.control` (8). The cover in it has `Radius.control` and
  sits `CardFrame.inset` in, so the two curves share a center, the rule the
  design system already keeps for every card.
- The buttons' ground under the pointer is round (a capsule's control);
  the progress line is a capsule.
- The buds stand 6 points off the island and the rows 6 points apart, wider
  than the 5 points the glass melts across (`IslandGlass.melt`): at rest they
  are separate drops, and only on the way do they hold on by a neck.

## How it is built, and what it costs

The glass is the system's: one `NSGlassEffectContainerView` holding an
`NSGlassEffectView` for the island and one per bud, so near drops melt into
one and part with a neck, drawn as signed distance fields on the render
server. Their frames and corners move by `NSAnimationContext`, on a curve
with a little overshoot (`Curve.give`) for opening and a plain one for
closing.

Everything drawn over the glass (covers, words, bars, progress, buttons,
the buds' faces) is layers of ours in `InkView`, moved by Core Animation on
the same curve and time. The bars loop on the render server at up to 24 fps,
the progress line runs to its end by itself at up to 15 fps, and only the
times tick, once a second, while the card is open.

Measured on a probe world, the Mac's load average around 50:

- At rest, playing, 10 s: the main thread 14 ms (bars and all on the render
  server).
- A skip: 6 ms of the main thread.
- Opening or closing, 0.6 s: 40–55 ms of the main thread. Liquid Glass can't
  be moved on the render server: `NSGlassEffectView` is a SwiftUI view inside
  that sets its distance-field layers from the main thread every frame, and
  an animation of the layer under it doesn't move the glass (tried: it jumps
  to the end). About 60% of that time is that inside view, about 20% the
  window's hosting view laid out each frame, the rest AppKit's animator.
  So the frequent path stays still: nothing moves under a passing pointer,
  the island opens only once the pointer rests.

The island lives outside the column's clip (an overlay in `Peek.swift`),
so the open card can reach past the column's edge; the column's hit test
lets a click there through to the island alone. A click 60 points over the
island at rest lands on the foot under it (the view is as tall as the
island open, but takes the pointer only where the glass is): `./bench
band` reports it as `over_island`.

## The bench

`./bench band ACTION [SECONDS]` reports the island's state after ACTION:
`open`, `close`, `next`, `previous`, `toggle`, `cycle`, `back`, `bud:N`,
`back15`, `forward15`, `swipe:DX`,
`click:play|next|previous|back|forward|sound|tab|bud|line|title`, `point:SPOT`, and on
test runs `pretend:N` (that many tabs playing made-up tunes with covers),
`skip` (the island's site skips), `sitepause` (the site pauses or plays),
`gone:N` (the Nth stops, 0 the island), `live:S` (the island's a live
stream S seconds behind its edge), `menu` (the right-click menu's items
into the report), `menu:TITLE` (that item chosen), `shown` (turned back on). `deaf` makes it ignore the real
pointer. Real events through the window: `press:F`, `drag:F` and `lift:F`
(the mouse on the open card's line, F along it), `fingers:DX` and
`fingers:up` (two fingers on the island, sideways, then lifted).
`grab:PATH` writes the window as the window server has it, glass and all,
with `PATH.json` beside it (the island's frame and the corners AppKit
worked out). The report has the island's and the buds' frames in the window,
the glass's class, and the main thread's time.
`evals/player-scrub/check.py` drives a real page with them.

## Not done

- Live YouTube Music and Spotify, for their next and previous buttons and
  covers, are still unchecked with buds.
- No island with tabs on top: there is no column.
