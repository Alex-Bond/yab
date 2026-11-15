# Yab for iPhone: working in Phone/

The repository's AGENTS.md applies here too. This file adds what is specific
to the iPhone app.

## Build and run

- XcodeGen generates the project from `Phone/project.yml`; the project file
  is never committed: `cd Phone && xcodegen generate && open YabPhone.xcodeproj`.
- Set your own team under Signing & Capabilities and run it in an iOS 26
  simulator. The deployment target is iOS 26.0.

## Code

- SwiftUI first, UIKit where SwiftUI can't give the frames (page paging, the
  spaces' springs, the field over the keyboard). Liquid Glass through
  `.glassEffect()` and `GlassEffectContainer`, never a hand-made blur.
- Every size comes from `Design/Metrics.swift`, every animation from a named
  spring in `Design/Motion.swift`, every haptic through
  `Haptics.play(_:reason:)`.
- Shared files (`Design/*`, `Model/*`) take the smallest additive change: a
  new property or a new case, not a rewrite.
- Named states for screenshots: launch arguments `-YabWorld <name>`
  (`Phone/Worlds/<name>.json`) and `-YabState <state>`. Each feature registers
  its states in its own `Testing/States+<Feature>.swift`; a UI change shows
  the states it touches before and after.
- Test pages are local fixtures (`Phone/Resources/Pages/*.html`), never the
  internet.
- Code, comments and commit messages in American English, no em dashes.
  Comments say why, briefly.

## Versions

The version is `MARKETING_VERSION` in `Phone/project.yml`, set once for the
app, SyncKit and the Activity extension. Maintainers set it when they cut a
release; pull requests leave it alone.
