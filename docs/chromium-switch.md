# Engine switching state

The switch track adds state handoff to the existing Opens in replacement seam.
The normal WebKit-only factory does not start Chromium or a cookie bridge.

## Cookies

For persistent website stores, ordinary Chromium navigation and WebKit navigations in a Chromium-enabled tab
wait for `ChromiumDRMCookies.synchronizeForSwitching()`. Unlike the original DRM
host filter, this reconciles the whole paired sign-in profile, including identity
providers before redirects. The existing HTTP-only, SameSite, host/domain and
partition checks remain. Partitioned cookies are not flattened.

`ChromiumSwitchCookieLedger` persists the two last successful snapshots as SHA-256
fingerprints. Cookie values are never written to this ledger. Files are atomic,
mode 0600, inside a mode 0700 directory in the current Store world. Private stores
have no ledger. A restart uses the fingerprints to distinguish an edit or sign-out
made while the other engine was off from a previously unknown cookie. On a helper
loss during a running app the reconciliation resets to bootstrap policy, so loss
of its context cannot empty the still-live WebKit store. Simultaneous conflicting
edits retain the existing WebKit-wins policy.

CEF profile identity is still space-based at this baseline. This wave does not
migrate old CEF directories, merge shared-space profiles, or fix private-context
lifetime. The new ordinary navigation barrier skips private and other nonpersistent stores, and private DRM bridges keep their earlier filtered scope rather than synchronizing all sites. Do not claim complete sign-in profile parity from the cookie fixture.

`EngineSwitchQuit` completes a final barrier before `KeptCookies.save` and before
AppKit enters terminateLater. It first cancels termination, synchronizes live
bridges on the normal loop, then resumes the already-consented quit. A five-second
deadline prevents a dead helper from holding Quit; a timeout or bridge error is
not a successful transfer. A WebKit-only session with no bridge skips this phase.
The synthetic eval disables automatic polling/observation with the test-only
`YAB_SWITCH_COOKIE_SYNC=manual`, so its last Chromium write must cross at Quit.

## Live document handoff

`EngineSwitchDocument` captures only the current main document at the exact URL
being switched, in the engine's client world. Local and session storage are restored
at document start, before the destination site's scripts. Storage is scoped to the
origin and session storage stays scoped to the Tab. No child-frame state crosses.
At DOMContentLoaded it restores matching ordinary input/textarea/select controls
and scroll position. Password, hidden, file, payment and one-time-code fields are
excluded. A changed DOM control identity is left alone; no synthetic submission or
input/change event is emitted.

Private and other nonpersistent stores retain the earlier engine-switch behavior; this new document handoff is limited to persistent stores until CEF profile identity and private lifetimes match WebKit.

The payload stays in memory and is limited to 512 KiB. An oversized snapshot is
refused before the source page is retired. A provisional or unavailable document
has no transferable snapshot. A revision, source-page identity, target URL and
profile check still protects replacement after async capture and cookie work.
A rapid second switch can carry a pending snapshot before its first destination
has committed. Scripts are removed after the destination finishes, so reload and
Back cannot replay stale storage. Redirects do not receive another URL's payload.

This is a live Opens in handoff, not a cross-launch origin storage migration.
Global restart storage, IndexedDB, CacheStorage, service workers, native visited
state and complete back/forward stacks remain separate required capabilities.

## Certificate decisions

Both engines now read/write `CertificateExceptions` through the Tab's actual
WebKit website store. Private grants follow that store's lifetime rather than a
Chromium space name. Only the exact endpoint and chain are shared. A changed
profile, host, port or chain cannot reuse a decision. Existing persistent
`chromium-<profile>` grants migrate on matching lookup, preserving the approval
date and removing the migrated legacy entry. Clearing site data removes matching
legacy keys as well. OS trust settings are never changed.

## Acceptance

`evals/chromium-switch/cookies.sh` builds the real signed app and YabCore through
the farm. `cookies.py` checks request-time cookies after restart, repeated live
switches, sign-outs during a WebKit-only run, storage before page scripts, ordinary
form drafts, scroll and edits retained after a real reload. A self-signed loopback
TLS fixture checks approvals in both directions and refusal on another exact
host. Pictures use ScreenCaptureKit. Assertions and captures must be read before
any wave is marked verified. See the track REPORT for exact source/job IDs.
