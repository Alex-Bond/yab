# Sidebar acceptance: Dia

The user selected Dia on 2026-10-22. This supersedes the Arc-style pinning
choice. This document is a contract, not a claim of acceptance.

## Behavior

- Ordinary show/hide: panel and responsive page move together, with no
  backward correction of the page at a WebKit paint or at completion.
- Floating reveal/hide: the page's geometry and scroll position stay put.
- Pin from floating: adopt the docked page width directly, as the captured
  Dia does; do not replay an ordinary slide from the window edge.
- Reverse or repeat a command during motion: continue from the visible
  geometry; callbacks of an older operation cannot complete the newer one.
- The final page is live, sharp, interactive and at the correct viewport;
  no exposed backing, retained snapshot or paused video after a transition.

## Acceptance

Captured pixels, not scheduled animation duration, decide success. Require
valid endpoints, all required scenarios, known display scale and a full
post-transition capture. Missing or invalid evidence fails closed.

On the marker fixture, ordinary show/hide must have at most 2 pt backward
center movement; layout error and right-edge drift may exceed the matched
Dia reference by at most 2 pt. Floating transitions may move page markers
by at most 1 pt. Pinning must be atomic within capture resolution (at most
one intermediate page geometry), with no backward correction.
Interrupted motion must meet the same layout-error and right-edge limits
throughout the capture; returning to the correct final position cannot
erase a transient jump.

Gate on a small set of repeated native transitions. Before acceptance, also
check real responsive pages, dark/glass, both sidebar sides, full screen,
many tabs, fast reversals, scroll position and live video on 1x and Retina.
Retina is mandatory; 1x is not a substitute. Record app hash, source base
and patch, host, point/pixel sizes, scale, capture intervals and worst take.

The user's follow-up extends the common viewport coordinator to DevTools,
chat and split, including divider drags and SplitRule's direct preview.
Pointer targets stay direct, without an added easing curve. The coordinator
coalesces intermediate targets and waits for the final viewport's paint.
Fixed device emulation keeps its specified viewport; WebKit's docked native
inspector keeps ownership of its own frame.
Do not tune timing to conceal layout errors. Do not relax a threshold to
make a candidate pass; retain rejected candidates and their measurements.

The response time and movement to 95% must not exceed the matched Dia
worst take by more than one captured frame interval. Except for direct
pinning, visible movement must also last at least the shortest Dia take
minus one captured interval: an instantaneous ordinary jump is not parity.
A clean but delayed transition is not equivalent. The screen gate creates its own 2x test
display, verifies the captured scale, and tears it down on exit. This is
Retina rendering evidence; the user's physical Retina panel is a separate
final visual check.

## Current work

- The current gate has 158 checks per display scale. Earlier 133-, 146- and 152-check
  recordings remain historical evidence, not acceptance of this candidate.
- The candidate couples page origin to WebKit's viewport paint, pins the
  floating panel directly, and preserves the newest requested state during
  repeated commands. The previous candidate passed 39 native state/layout tests;
  the response candidate passed 40 tests. The new commit-barrier change
  still needs its native run. Thirteen local evaluator
  tests pass, including Retina pixel scaling and invalid pin preparation.
- Physical Retina smoke job `5aea344237e4497e` recorded ordinary open and
  close in the candidate and Dia. Candidate reverse movement was 0 pt in
  both takes. One repetition of two flows is diagnostic evidence only.
- Full captures abort if the target loses live Accessibility focus. A
  partial run, a lost-focus recording or missing scenario cannot pass.
- Completed run `e8c945ea6fa5460b`: 101 functional checks passed over
  24 captures (live video, scroll, input, glass, right sidebar, 24 tabs,
  full screen and a real responsive page). Its 2x pixel gate still failed
  10 checks, predominantly response time. The 1x gate failed 25 checks,
  including an observed reverse step and missing transitions. Two 1x Dia
  captures lost final focus. This is not acceptance.
- The recorder is headless and prepares/asserts the scenario after helper
  startup, before its baseline/action clock. Pinning with no floating card
  now fails validation; the earlier invalid pin is retained as evidence.
- Current response work avoids republishing an already prepared card,
  counts preparation inside the existing hover dwell, and removes the
  sidebar's extra exit grace. Animation curves and acceptance thresholds
  remain unchanged. A new complete native run is required.
- The latest geometry change keeps the viewport request in flight until
  Core Animation's outer transaction has committed. WebKit's presentation
  callback is invoked while that transaction is being assembled; clearing
  the request there allowed another resize to overtake the pending origin.
  A nested-transaction test and a scoped native before/after check are
  prepared. This is a hypothesis under validation, not accepted parity.
- No product commit, merge, push, release or reporter acceptance yet.

## Shared width changes, pending verification

All normal animated page resizes now use StageView's native coordinator.
Browser.trackingSize covers split, DevTools and chat dividers; SplitRule's
preview feeds the same coordinator while avoiding SwiftUI layout per move.
Same-size relocation, repeated layout, mouse-up's last target, and lending
the live page have explicit handling. This is implementation status, not
a smoothness or parity claim.

ViewportResizeTests uses real WebKit to check those paths, including a split
preview that lands in its final stage. The focused physical check is one
short clip with DevTools open/relocate/close, chat open/resize/close, and
split open/resize/close. It preserves the document and scroll and checks
that each actual app path invoked the coordinator. No new Arc/Dia matrix
is needed for this extension.

Verification on 2026-10-22: job `2c23381f003c4549` built the candidate
and passed all 45 Swift Testing methods in six suites, including all four
ViewportResizeTests methods. The short physical Retina run passed DevTools
open/close and chat open/resize/close with document and scroll retained.
Its split fixture was incorrectly left as an agent bench tab, which the
product deliberately refuses to pair. The fixture now adopts its own two
tabs before testing. A corrected physical run is pending; this commit is
not full visual acceptance or a release.
