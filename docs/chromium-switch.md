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
made while the other engine was off from a previously unknown cookie. A new
helper, at launch or after a lost one, has the session cookies that reached the
profile's disk (`persist_session_cookies`, measured by
`evals/chromium-switch/signout.py`; a crash can lose the last few seconds'). The
session cookies both jars agreed on go back from WebKit at once anyway, before any
host is read, and the ledger is kept. Until November 2026 the ledger forgot every
session cookie instead, on the belief that a new helper had none, and until its
host was read again a cookie Chromium had deleted looked never seen: WebKit's copy
went back. That was the 0.46 report "signed out, Continue with Google, signed in
as the old account": the provider's ended session cookie returned to Chromium from
WebKit on the first read of the provider's host after the sign-out. A put-back that
fails falls back to forgetting.

Two jars for one person have one rule: a session cookie a site rotates must never
go back to an older value, because a site can end a session that shows one (Google
does). So:

- A value changed on one side goes to the other, a deletion as much as an edit.
  Changed on both: a value one side moved away from (deleted it, or signed in to
  another account) loses, renewed or not, since a site renews a session it still
  sees (a new expiry, the same value); a sign-out of one value leaves another
  side's new sign-in alone; two new values go to the engine that used the host
  last; with nothing known yet, the WebKit sign-in. Each print in the ledger is a
  short hash of the value, then of the whole cookie, so this needs no value kept.
- The ledger records what each jar holds after a pass's writes, read back, not
  what was sent: a write a jar dropped is not taken for that jar's own edit.
- A session cookie the bridge deletes from WebKit reaches the keychain copy
  (KeptCookies) at once, not half a minute later, so a crash can't restore it.
- A first request on the engine that didn't use the host last waits for the host to
  settle, up to 5 s, not the 0.75 s of a repeat. A crossing, the other engine having
  been the last to use anything, settles every host that engine has used since the
  last one: frames, redirects and requests can reach any of them, and only WebKit's
  frames can be held back.
- WebKit's frames wait as its pages do (`prepareFrame`). Yab's own requests with
  WebKit's jar, live folders, extension fetches and agents' reads, go through
  `ChromiumDRMCookies.beforeSending`: under Auto that jar has no page to keep it fresh.
- Chromium says nothing of a changed cookie, and WebKit says late. While Chromium has
  pages, `keepInStep` reads a site open on both engines every 3 s and twelve of
  Chromium's hosts every 15 s, in turn, frames' included.

What is left: with one site live on both engines, a rotation on one reaches the other
within 3 s, and a request sent in that time goes with the older value. Chromium's
frames and subresources can't be held back, so a host WebKit changed that Chromium
wasn't told of (the 15 s, or a crash before a quit's last pass) can leave old. The
fixture cannot show what a real service does beyond its rule: Google's device-bound
sessions, or how it reads one session from two engines' fingerprints.

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

This is a live Opens in handoff. An origin's storage across launches is
EngineStorageCarry's, below. CacheStorage, service workers, native visited state
and complete back/forward stacks are not carried by either.

## Origin storage

`EngineStorageCarry` (one per persistent cookie bridge) keeps localStorage and
IndexedDB with the engine a site opens on, whichever road brought it there: the
default changed, a rule, memory, an update from a WebKit-only version.

A ledger (`engine-cookies/<id>.storage.json`) names the engine that last used each
origin. The first request on the other engine (`ChromiumDRMCookies.prepare`, in
either engine) waits up to 2.5 s while `Resources/PageScripts/engine-carry.js` reads
the origin on one side and writes it on the other, in an empty document at that
origin on each: a hidden WKWebView with a simulated response, and a hidden helper
tab with `tab.loadHTML`. No request leaves and none of the site's code runs. The last
user wins: the destination's localStorage and databases are replaced, so a sign-out
on one side reaches the other. A read that fails writes nothing.

An origin with no ledger row has only WebKit's past, and WebKit's data records say
whether it has anything, so a first visit to a new site costs nothing.

Nothing is written into an engine that has a page of that origin open, or after the
wait ran out: the page would have its storage changed under it. The ledger stays as
it was, and the next launch tries again.

It carries structured clone's values: Date, RegExp, Map, Set, BigInt, ArrayBuffer,
typed arrays, Blob and File. A record that can't be written as text stays behind, a
CryptoKey or a class instance, and an origin over 24 MB of them, or using over 96 MB
in all, carries localStorage and leaves its databases where they are. Also not carried: a third-party frame's
storage, session storage (a live switch's), service workers and CacheStorage.

## Default engine

With no choice made, a build with bundled Chromium on arm64 is on Auto, a new install
and an update from a WebKit-only version alike (`PageEngineSelection.requested`). An
Intel Mac or a build without Chromium stays on WebKit and shows no Engine rows. A
choice made by name is kept: `YabPageEngine` (`webKit` or `chromium`) and
`engine.default` (`auto`, `chromium` or `webKitFirst`).

| Default | A tab with no rule | Opening or waking while memory is tight |
| --- | --- | --- |
| Auto | Chromium | Chromium |
| WebKit First | WebKit | Chromium |
| Chromium | Chromium | Chromium |
| WebKit | WebKit | WebKit |

Under Auto a page whose player refuses Widevine (Yab's Chromium has none) moves to
WebKit, for that site only (`Tab.engineProtectedSite`, its registrable domain).
Chromium picked by name moves no page on that guess; the built-in rules, listed in
Engines for Sites, apply to both. A tab on WebKit for a site's rule or video goes
back to the default's engine at the next site a person sends it to (a link clicked,
an address typed): `Tab.routesToChromium`. A redirect or a script on its own stays
on the engine its flow began on, and so does a window another page opened.

A tab memory moved says so (`Tab.engineMemoryMoved`) and goes back to the default's
own engine the next time it wakes with memory to spare. Own rules, built-in rules and
⌘K's Open in all win over memory.

No default moves a live page. The transaction is safe but not invisible: a move is a
reload, and a page's memory, video position, connections and script state don't
carry. So memory acts only where a page is being built anyway.

On the first launch after an update, `EngineRules.restored` gives every restored web
page the default, so the session comes back on Chromium, the one tab in front at once
and the rest as they wake. Extension pages keep the engine that owns them. Cookies
import in the background, each host's own first, and each origin's storage comes
across the first time it opens.

## Extensions

There is one list of extensions, whichever engine draws a page
(`ExtensionOneList.swift`). A sign-in's list on disk (`Extensions/installed.json`,
`Sign-Ins/<space>.json`) says what is installed, in what order, on or off and
pinned; Store.settings says where each may reach and what it was given later.
WebKit's `Extensions` owns that list, at rest or running. A CEF profile is a copy
kept in step with it (`ChromiumExtensionSync.swift`): `converge` compares the two
when the first page opens in a profile and after any change, and does what
differs, so a change made while the helper was down is done next time it is up.
Chromium's Settings rows and column read the list's entries, in its order, and
Chromium's pins are the list's (`pinnedIDs`). Store extensions only: a folder's
has no package Chromium could verify and stays WebKit's.

The first time a profile joins, the two lists Yab kept before become one, once:
everything in either, on if on anywhere, pinned if pinned anywhere, Chromium's pin
order first, a site-access choice made only on Chromium kept. `Migration.joined`
marks it done and from then on names what the profile held when it last matched,
which tells one removed from the list while the helper was down (uninstalled from
Chrome) from one newly installed on Chromium (taken into the list). A pass names as
matched only what Chrome and the list both hold, or what was matched before and has
left the list since (`ExtensionOneList.matched`), never one Chrome took in while the
pass ran: that one isn't in the list yet, and the next pass takes it in. Named as
matched, it read as removed from the list and was taken off Chromium (2026-11-05:
six added a few seconds apart, three kept). Such an arrival asks for one more pass
(`ExtensionOneList.wantsPass`). An entry
missing from Chromium is always brought back rather than taken off the list: a
damaged profile must not cost anyone an extension. An unreadable list stops all of
this (`Extensions.loaded`).

Entries are fetched as original packages (`ChromiumPackages`, kept or from the
store) and WebKit's copy of one that came in on Chromium is made from the same
package, with the shim (`Extensions.fillFolder`). No question for what was
approved. WebKit's saved approval lists only what WebKit understands, so the bar
is `ChromiumExtensionGrants.beyondApproval`: a permission Chrome warns of
(debugger, tabCapture, history and the like) or a site the approved manifest
didn't have. One that wants that stays in the list with `chromeAsks` set and,
while on, asks once in Yab's own question; a no leaves it listed and off until it
is turned on, anywhere, which asks again. One that is off waits to be turned on.
Settings shows it, off, the whole time (`Item.absent`).

With Chromium the default, WebKit's extensions rest (`Extensions.restsForChromium`):
none loads until a web page on WebKit appears, or every extension would run twice.
Even then, one the Chromium profile holds now stays asleep
(`Extensions.restingInChromium`): that WebKit page has the Chromium copy's scripts
over the bridge, and a WebKit copy woken beside it would run what was taken away
there. So with Chromium the default a WebKit tab draws buttons only for extensions
Chromium doesn't hold. At rest the list still changes: an install writes it and its
folder, and the launch that wakes them loads what is there. A carry 0.46.0 owed
(`Migration.storageOwed`) is paid by the first crossing.

chrome.storage, local and sync, is kept one in both engines, key by key, both ways
(`ChromiumExtensionStorage`). `Shadow` keeps a hash of each key as both sides last
agreed and each side's file times, so a key gone from one side reads as removed,
nothing opens while neither moved, and a key both changed goes to the side written
last. WebKit's side is its SQLite database, written directly since at rest no
context exists to ask; a running WebKit copy reads the new value on its next get
and hears no onChanged. Chromium's side answers only in one of the extension's own
pages, so one that is off crosses when it is turned on. Yab looks at the files every
five minutes at rest, every twenty seconds while WebKit runs extensions, and right
before WebKit wakes (`bringStorageHome`). What doesn't cross: anything an extension
keeps elsewhere (IndexedDB, storage.session, an unlocked vault).

Optional grants given in either engine are held in both (`ChromiumExtensionGrants.
cross`): one going to Chrome goes through chrome.permissions.request, whose question
Yab answers yes since the person already gave it (`ChromiumConsent.approve`). They
cross when an extension arrives or turns on, and when one is granted on Chromium.

Per-site access is one setting (`Extensions.access`, `allowed`), shown by the same
rows in both engines' Settings (`ExtensionWebsites`) and said in Chrome's runtime
host permissions (`extension.access`). Blocked sites have no per-extension form in
Chrome: they stay WebKit's, and Chromium's Settings doesn't offer them.

Chrome has no getter for chrome.action.setIcon, so the icon is read off the worker's
own calls, and a hook put in over CDP comes too late for one that sets it as it
starts, as Bitwarden sets its lock. So a package's worker starts with the hook
(`ChromiumActionHook`, `ChromiumExtensionPackages.arm`); a package from before takes
it with one reload, once, and WebKit's copy has it taken out (`plain`). The hook adds
no tab listeners, which at a worker's first line would wake it for every page. An
icon set for every tab outlives the worker in `ChromiumColumn.everywhereIcons`.
Both engines draw a badge in Yab's own colors, not the extension's.

`evals/chromium-extensions/one_list.sh` is the proof: a world in the state two lists
left, then the migration, both directions of everything above, a relaunch, and a
WebKit tab beside a Chromium tab.

## Certificate decisions

Both engines now read/write `CertificateExceptions` through the Tab's actual
WebKit website store. Private grants follow that store's lifetime rather than a
Chromium space name. Only the exact endpoint and chain are shared. A changed
profile, host, port or chain cannot reuse a decision. Existing persistent
`chromium-<profile>` grants migrate on matching lookup, preserving the approval
date and removing the migrated legacy entry. Clearing site data removes matching
legacy keys as well. OS trust settings are never changed.

## Clearing

Both engines hold a sign-in, so everything that clears reaches both, whichever
engine shows the page now. Chromium's Settings page is the one caller of its
BrowsingDataRemover and of its site data model, and neither has a CEF or DevTools
entry, so `ChromiumSiteData` opens a hidden `chrome://settings` tab in the profile
and sends it the page's own WebUI messages: `clearBrowsingData` for Sign Out, Clear
Cache and Clear History, `clearSiteGroupDataAndCookies` for Site Controls' Clear Data.
A new store in a later Chromium comes with those messages. One site's HTTP cache has
no way out alone, so forgetting a site empties the profile's cache; other sites keep
their sign-ins. Clear Cookies and Refresh deletes the site's cookies over DevTools, in
private pages too. A sign-in that never used Chromium has no folder and starts no
helper. A deleted space's folder and cookie ledger go at the next launch, or before
the next helper starts: a loaded profile keeps its files open.

Chrome's password manager, autofill and form history are off in `ChosenPreferences`,
so nothing is kept there to clear. Its `Sessions` files are removed at each helper
start, as Yab restores tabs itself. `evals/chromium-platform/privacy.py` proves all of
this by walking every file of a world for a unique mark.

## Acceptance

`evals/chromium-switch/modes.sh` takes a signed app and a WebKit-only release and
walks every road there and back on a signed-in fixture site and on a session that
dies on any older value, then opens the release's world with the new build (`docs/testing-real-profiles.md` has the real-profile run,
`scripts/cef/real-profile.sh APP --upgrade`). `evals/lowram/modes.sh` measures the
default engines on 8 GB.

`evals/chromium-switch/cookies.sh` builds the real signed app and YabCore through
the farm. `cookies.py` checks request-time cookies after restart, repeated live
switches, sign-outs during a WebKit-only run, storage before page scripts, ordinary
form drafts, scroll and edits retained after a real reload. A self-signed loopback
TLS fixture checks approvals in both directions and refusal on another exact
host. Pictures use ScreenCaptureKit. Assertions and captures must be read before
any wave is marked verified. See the track REPORT for exact source/job IDs.
