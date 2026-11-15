# Engine switch acceptance

Run `cookies.sh` through a display farm job with `--needs release-signing,capture`.
The job builds the real app and YabCore, verifies Developer ID signing and the
visible task name, and runs `cookies.py` with a deadline. Every request has a
socket timeout, launches/termination have deadlines, and only owned app processes
are closed. Pictures use ScreenCaptureKit beneath the blackout.

The fixture creates only synthetic HTTP-only and script-readable cookies on
loopback, in a fresh `YAB_PROBE` world. It checks the first request after WebKit to
Chromium restart, live same-tab engine replacements in both directions, edits,
sign-outs, and profile isolation through the existing DRM cookie contract. A
WebKit-only restart changes cookies while the Chromium bridge is absent; the
next Chromium launch must retain that sign-out. No real accounts or credentials.

`summary.json` records each assertion and picture. Read every cited picture.
Passing this eval does not establish storage/IndexedDB, profile migration, global
live replacement, back/forward or scroll/form transfer parity.

The combined state wave additionally checks localStorage/sessionStorage at the
first inline script, ordinary drafts and scroll on live Opens in changes, and
post-switch edits after a genuinely committed reload. It exercises exact-chain
TLS approvals in both directions using a self-signed loopback fixture, with no
OS trust changes. It does not prove global restart storage or arbitrary web-app
DOM restoration.
