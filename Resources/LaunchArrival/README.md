The opening is adapted from an earlier onboarding by the same author:

- `mac/App/Resources/OnboardingShaders/Waves.metal`: Ray/Flow radiance and bloom.
- `mac/App/Interface/Onboarding/IntroPlayback.swift`: the original pacing keys.
- `mac/App/Resources/OnboardingSounds/arrival-02.m4a`: unchanged Warm analog.

The palette is derived from the Mac's `NSColor.controlAccentColor` in linear
RGB. The browser replaces the original's collected logo: collection is disabled
and the carrier contains emitted light only, without a window-coloured
proxy. The approved handoff runs from audio time 5.36 to 5.66: the ready
native window fades in as the light fades out with the same 300 ms curve.
The original 5.56 audio cue still anchors the Ray/Flow pacing, and the
unmodified soundtrack finishes naturally. The first window is reserved
before SwiftUI orders its empty surface, preventing an initial white flash.

Sound SHA-256: `884775ae5fb0424230b78b310141d7353c54affb315ecdfef13cec70262db4bf`.

The animation plays once in the life of a Mac: on the first ordinary
foreground launch, before the welcome, opened from the disk image too (the
window then stays where it opens instead of growing from the image's window),
and never again once it has played (`launchArrivalSeen`) or Yab has been
welcomed. Show Again in Settings (and Help > Welcome…) plays it again before
the welcome. `YAB_LAUNCH_ARRIVAL=1` still plays it for probes. Tests skip
it unless `YAB_LAUNCH_ARRIVAL=1` is set. `YAB_LAUNCH_ARRIVAL=0` skips it in any
launch. Neither override bypasses Reduce Motion or background/headless launch. A focus change, Escape, hiding, closing,
moving or resizing the window cancels it and restores the native window.

Build and native visual acceptance are registered in
`qa/pending/launch-arrival-firstlight.json` for the shared QA batch.

## Disposable arrival preview

`qa/checks/build_launch_arrival_preview.sh` builds the separately identified
`dev.serafim.fast.launcharrival.dev` app with `YAB_LAUNCH_PREVIEW=1`. Run the
script through the shared farm queue. The preview bypasses the ordinary
packaged-app cache while retaining the incremental compiler cache.

The signed app includes `YabLaunchArrivalPreview=true`. Only the combination
of that flag and its dedicated bundle identifier enables the reset: every
process creates a fresh, short test-world name before Store is read, ignores
saved AppKit window state, and opens a 1180 by 780 point window centered on
the display under the pointer (clamped to fit). It skips the welcome overlay
so that only the arrival animation is being reviewed. The normal browser
and ordinary dev app do not enter this mode.

The preview writes `YAB_LAUNCH_PREVIEW` JSON lines to stderr for placement,
start, reveal, finish, geometry changes and cancellation reasons. A successful
full reveal needs placed/start/reveal/finish with unchanged window frames;
a centered final window alone is insufficient acceptance.
