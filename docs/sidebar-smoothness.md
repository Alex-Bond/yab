# Sidebar smoothness (feedback #162)

Feedback #162 (0.0.30, macOS 26.7, no email): opening and closing the sidebar
with ⌘S is less smooth than in Dia and Arc. Studied on 2026-10-19 (2996b2fd).
Not fixed yet. Register row 240 is Open.

2026-10-22: the user selected **Dia for all sidebar transitions**. The
implementation and binding acceptance contract are tracked in
[sidebar-dia.md](sidebar-dia.md). The current candidate is under test;
neither this study nor a passing build closes the reported problem.

## What the study found

- **The column moves like Dia's.** Both reach 95% about 100 ms after the
  first move (Yab 97–111 ms, Dia 93–114 ms on m4; within two 70 ms frames of
  each other in the reporter's clip). One small difference: when the sidebar
  comes back, Yab's edge starts faster (50% at about 23 ms, Dia's at about
  45 ms), which makes the stale layout below travel a little further.
  Putting it away is the same in both.
- **The page is what differs.** In Dia the page content stays within 2 px of
  where a page laid out at that width would be (12 of 13 presses). In Yab it
  is 45–61 px off (about 110 points on the reporter's screen) in 6 of 9: it
  rides with the column at its old width, then snaps back by about half the
  column when WebKit's new layout arrives. Putting the sidebar away also
  shows a blank strip at the right edge for 2–3 frames.
- **Why.** During ⌘S Yab carries the page at its old size with Core Animation
  and hands WebKit one new width at a time (`StageView.following`,
  `Sources/Fast/Stage.swift`). Until WebKit has drawn a width, the old layout
  shows. On yetanotherbrowser.com WebKit takes a median 41 ms per width (up
  to 80–89 ms) on an M4 and an M1 Pro at 1x, against 21–27 ms on
  diabrowser.com. By the time the first new layout is on screen the column
  is 75–84% of the way there.
- **Not Yab's main thread.** Worst frame 16.7 ms in busy and dark/glass runs,
  one 33 ms frame in 16 plain presses, 6 dropped frames in 16 presses with
  200 tabs; none line up with the snaps.
- **Retina makes it worse.** The reporter's clip has a laptop's proportions
  (1470 × 956 points, Retina): about 4× the pixels per width of the 1x farm
  Macs. A width then lands only after the motion, so the whole slide carries
  the old layout and the page snaps once at the end. m4 shows the same with
  live widths turned off (content off by 87–91 pt, snap back 86–89 pt).
  Busy CPU, 200 tabs and glass make it somewhat worse (glass: 51 ms per
  width, snap back up to 117 pt).

## Plan

1. Measure how Dia keeps its page in place: does it lay the page out at the
   final width before the column moves, or show a stretched or clipped
   snapshot until the new layout lands?
2. Try in Yab, each as an A/B on the same pages:
   - give WebKit the final width before the slide starts, and slide only the
     column over the already-resized page;
   - or keep the page's last frame as a snapshot, clipped (not shifted) to
     the space it will have, until WebKit draws the new width, then swap.
3. Remove the blank strip at the right edge when the sidebar goes away.
4. Check on a Retina laptop-sized window, not only at 1x: that is where the
   reporter sees it.
5. Done means: page content within a few px of its final place in every
   frame, no snap back, no blank strip, on yetanotherbrowser.com and the
   reporter's pages, Retina and 1x, plain, busy and glass.

## Evidence and tools

- Results page with frames: [docs/evidence/sidebar-162-2026-10-19/index.html](evidence/sidebar-162-2026-10-19/index.html)
- Frames from the reporter's clip: `reporter-yab-*.jpg`, `reporter-dia-*.jpg` there.
- Harness: `evals/sidebar-162/` (`film.py` films ⌘S in Yab and Dia, `clip.py`
  reads a clip frame by frame, `page.py` measures where the page content is,
  `env.sh` sets up the run). Farm jobs from the study: m4 8b7929fa3b964a96,
  96eb2a94a62545a9, adhd 34ccc79b1d634211.
