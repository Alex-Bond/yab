# Yab for iPhone on iPhone Duo

What Apple says about building for iPhone Duo, read on 2026-11-02, and where
Yab's custom chrome breaks it. The device, its simulator and the picked
design: the Duo simulator exists only on main (Xcode 27.2, iOS 27.1), it boots
folded, and the app runs on the cover (466×678, status column 84 wide on one
side).

## Sources

- HIG, [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- [ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion) (SwiftUI), [UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion) (UIKit)
- Tech Talks: [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/), [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/), [Strike a pose with adaptive layouts](https://developer.apple.com/videos/play/tech-talks/111463/), [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)

The doc pages render with JavaScript; their text is at
`https://developer.apple.com/tutorials/data/<path>.json`.

## Apple's rules

**The side column is shared.** On the cover, and unfolded in landscape, the
Dynamic Island, the status bar, the app's toolbar (Back included) and the tab
bar stand in one vertical column on one side. The outer camera's region
"expands into the Dynamic Island for Live Activities": the island grows down
the column, and app controls under it collapse into an overflow menu when
there is no room. Unfolded in portrait, bars stay horizontal. In Split View
each app keeps its column on its outer edge, so the column can be on either
side, and it stays with the hardware in right-to-left languages.

**Foreground inside the safe area, background may extend.** Interactive
controls and content that scrolls stay inside the safe area. Full-bleed
backgrounds may run under the column (`.ignoresSafeArea()`,
`backgroundExtensionEffect()` / `UIBackgroundExtensionView`). The full width
is allowed only for "visual, immersive interfaces that don't scroll", and only
when nothing conflicts with the Dynamic Island or the status bar (Calculator).
A full-width header with inset scrolling content is the combined form.

**Insets are asymmetric.** Handle each side by itself
(`bounds.inset(by: safeAreaInsets)`, never `width - left * 2`). Layout margins
are asymmetric too, so content can sit closer to the column.

**Use the system's vertical bar.** Bars from `NavigationStack` /
`NavigationSplitView` with `.toolbar` (or `UINavigationController` and
`UITabBarController`) go vertical by themselves and avoid the status bar, the
camera and Live Activities. Custom `UIToolbar`, `UINavigationBar` or
`UITabBar` content is not considered. Back or Close goes at the top
(`ToolbarItem(placement: .cancellationAction)`), prominent actions next
(`.topBarPinnedTrailing`), bottom-bar items at the column's foot. Items need
both a symbol and a title; text-only and custom views stay horizontal unless
`.axisBehavior(.verticalPreferred)`. `.visibilityPriority`,
`ToolbarOverflowMenu`, `.toolbarVerticalCompressionBehavior` decide what
overflows. A custom view learns where the bar is from
`@Environment(\.toolbarVerticalEdge)` / `traitCollection.verticalBarEdge`
(iOS 27.1). `.toolbarVerticalBehavior(.disabled)` opts out.

**Reserved regions for custom UI** (iOS 27.1): `occlusion` (the outer
camera and its Live Activity island, the inner camera while it is on) and
`division` (the fold, active only partly folded). SwiftUI:
`GeometryReader { proxy.reservedRegions(kind: .occlusion) }`; UIKit:
`view.reservedRegions(kind:options:)`. Frames are in the view's own
coordinates and already include the margins for interactive content. Keep
controls off the fold; scrolling content may cross it.

**Size classes, not idiom or orientation.** Compact width on the cover,
regular width inside. Don't decide layout by `userInterfaceIdiom`,
`UIInterfaceOrientation` or fixed display sizes.

## What Yab now does (2026-11-02)

1. **Page content respects both sides independently.** `PageViewport` keeps
   the hardware left and right edges in WebKit's minimum, maximum and current
   viewport, content and scroll-indicator insets. WebKit owns the background
   below the column. Failure-page text uses the same insets. Split companions
   receive only the hardware edge their pane touches. Explicit pane coordinates
   keep a horizontal page swipe from becoming an inset change.
2. **The custom rail reads the system.** Rehosting Yab's retained native plate
   and controls in a navigation toolbar would change its phone and tablet
   layouts, so it uses the custom-UI fallback. On iOS 27.1 and later, the window
   probe reads `verticalBarEdge` and active `occlusion`/`division` reserved
   regions. The rail centers in whichever one-sided column the window reserves;
   Back begins below overlapping occlusions that start above the column's middle,
   plus the status-bar height, retaining the idle y=172 minimum. The camera
   can stand at either end of the column. A foot occlusion lifts the space
   button to end 12 points above it; the top group is capped against that
   adjusted foot position.
   Sidebar follows Back. There are no measured column coordinates. The probe
   samples region changes while attached, including changes without a layout or
   safe-area callback, and publishes only changed snapshots. Region frames
   already include interaction margins. Older SDKs compile the fallback path;
   the new APIs are compiled with Swift 6.4.2 (the 27.2 SDK) and guarded by
   `#available(iOS 27.1, *)` at runtime.
3. **The foot belongs to the safe area.** Expanded and folded plates center
   between the asymmetric hardware sides. An active vertical division splits
   that foot into safe intervals; the row uses the largest interval. Controls
   intersecting another division move to the nearest fitting safe rectangle.
4. **Layout follows traits.** The unfolded presentation uses the regular
   horizontal size class instead of a 600-point minimum-side device guess.
   The system vertical-bar edge selects rail orientation and excludes the
   tablet toolbar. The legacy iPad idiom and minimum-size gate remains when
   no vertical-bar preference exists, preserving established iPad layouts and
   older-system behavior. Width limits for fitting two pages remain capacity
   checks, not device identification.

## The remaining proof

`Phone/Sources/Testing/States+Workspace.swift` contains `workspace.sides`, the
orientation states `duo.*`, and synthetic `duo.column.right`, `duo.column.left`,
`duo.activity` and `duo.division`. Synthetic states cancel an ordinary simulator's
symmetric cutout insets before supplying an 84-point column, and run the real
WebKit viewport path. They cannot prove the system's actual reserved-region
notifications or Live Activity geometry.

See `docs/evidence/iphone-duo-safe-area-2026-11-02/README.md` for the runs and
pictures obtained in this task. The folded-cover simulator check below now covers both directions. Final
device acceptance still needs unfolded portrait and landscape, Split View with
either outer edge, an external Live Activity while Yab is in front, and a
partly folded active division. Check fixed website controls,
scroll indicators, Back/Sidebar and the plate during rotation and page swipes.

## Duo simulator readings (2026-11-02 check)

The check on main's iOS 27.1 Duo simulator used the folded cover, not a
synthetic column. Portrait is 466 x 678 with right inset 84 and bottom 34.
Active window occlusions are `(399.667, 29.667, 37, 37)` and
`(382, 0, 84, 170)`. `statusBarFrame` is `(0, 0, 466, 2)`, not the
column's length; vertical bar edge is trailing. Back starts at y=172.

Rotated landscape-right is 678 x 466, left inset 84: occlusions
`(29.667, 29.667, 37, 37)` and `(0, 0, 84, 82)`, vertical edge leading.
Landscape-left has right inset 84 and reports the occlusions at the bottom:
`(611.667, 399.667, 37, 37)` and `(594, 384, 84, 82)`, edge trailing.
The landscape status bar frame is zero in both directions. No active division
was reported. Workspace reservations matched the window's readings.
The original rail incorrectly capped Back at y=270 and Sidebar at y=330
in the latter orientation, leaving the space button over the camera. The
camera-foot correction restores Back to y=172 and Sidebar to y=232, and
lifts the space button from y=390 to y=324. Its bottom is y=372, 12 points
above the camera region at y=384. The camera-at-top and portrait layouts
retain their previous positions. See the evidence's `fix-camera-foot/` folder.

Ordinary screenshot fixtures had skipped real viewport insets. The check fixed
that test path: fixture pages now apply side insets when hardware reserves a
side, so the saved pictures exercise the live page's viewport code. Content
fits beside either column; page background extends beneath it. The plate's
center is the safe area's center: x=191 portrait, 381 with the left landscape
column, 297 with the right. The existing live-page implementation was unchanged.

Clock could not launch: the simulator's application info provider returned nil
for `com.apple.mobiletimer`. External Live Activity expansion remains unproven,
as do actual unfolded, Split View and partly folded division behavior. A
forced wide workspace on the cover is not unfolded-device proof. See
[the device evidence](evidence/iphone-duo-check-2026-11-03/README.md) for all
five before/after cover pictures, raw notes and the Clock attempt.

The camera-foot regression fails against the pre-fix ChromeLayer and passes
with the correction. All ChromeSidesTests and PageViewportTests pass on Duo.
The requested combined run still has three BrowserWorkspaceTests failures,
reproduced with identical values against the pre-fix source; see the evidence
for their names and before/after summaries.
