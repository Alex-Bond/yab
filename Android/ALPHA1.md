# Android Alpha 1

Owner requested the first public Alpha on October 29, 2026. This is the usable
browser milestone, followed by incremental feature verification. It does not
claim that the stricter Beta 1 acceptance has passed. Keep existing features.

The candidate is `0.1.0-alpha.1` (Android versionCode 1), signed with the existing
owner key. The subsequent public build must use a greater versionCode. Use the
reviewed production source `1417d562ea9763bb1b4d3f29ab4ab91237f59f6b`; the two
unverified UI patches in the worktree are outside this candidate.

The previous unpublished Beta candidate had an empty `dev.yab.REPORTS_SITE` in
its actual binary manifest. Its feedback form could not send. The production
builder now supplies `https://yetanotherbrowser.com`, verifies the signed
manifest, and requires a genuine native form submission. A marked QA message
must also be found in the production admin before publication.

Alpha checks require a real launch, links, public search, history, keyboard and
Back, rotation, restart, retained data on reinstall, basic real Mac Sync, and
production feedback on the exact APK, with no observed crash or ANR. JVM, lint,
signature, Firebase, native layout and source checks remain required.
`scripts/alpha1-check.py` reads original producer/device receipts. The Beta 1
gate and its sixteen required scenarios remain intact.

Translation, the complete extension flow, folders/FCM, AI approval decline and
the outstanding full native suite failures remain experimental or unverified.
Do not describe them as accepted by the Alpha core checks. Feedback currently
accepts text and an optional reply email; Android has no photo/video attachment
control. A failed send retains the current in-memory text, not a durable draft
across process death.

## Accepted candidate, October 30

APK SHA-256 `412e117387b875b9bd6b01947d4fe517c00b8143fc41632da840485ce0612bcb`,
160,819,376 bytes, owner signed, source `1417d562ea9763bb1b4d3f29ab4ab91237f59f6b`.
`alpha1-check.py` passed in job `fe08eee18ac544b7` through `alpha1-retained.py`,
which repeats the device stage on these bytes without the signing key. The
original producer `8ef8ac11b3f24310` failed that stage and its receipt is kept
as `producer-result-original.json`. Static stages are from that producer. Launch,
links, history, search, keyboard, rotation, restart, reinstall, production
feedback and real Mac Sync passed on an owned emulator, with no crash or ANR.
No physical phone was used. The Mac peer was the retained compatibility build;
public Mac 0.43.1 contains Android Sync but was not itself run against this APK.

The harness changes were tests only. Known issue, not fixed here: a process
killed about 3 seconds after a navigation came back on the previous page in
`316dceca97124d78`; leaving through Home first keeps it. The saved Gecko session
is the likely cause, unproven.

Published October 30 at `https://yetanotherbrowser.com/android.apk`, a Vercel
project route (307) to the Blob object, and the public bytes match the hash
above. `vercel blob put` added a random suffix to the name despite
`--add-random-suffix false`, so take the URL from its output. The owner's
terminal ran the upload and route. Alpha 1 and 2 have no update path; builds after
them update themselves (RELEASE.md, "Auto-update"). The next build needs a greater
versionCode.

Never publish an older APK merely because a
new candidate is waiting in the farm. Web work uses Yab MCP; its upload tool
currently limits each file to 100 MiB, below the previous APK's 160,819,360 bytes.

## First tester reports and the search sheet, October 31

Merged, not published. Checked on an owned emulator through the farm with
`Android/scripts/sheet-check.py` (`--scenario sheet`, `--scenario pinback`), real
pages, no physical phone, no signed-in Mac.

Text (Wenuja, "Black color texts"): Compose's default ink is black, and every
screen standing on no `Surface` (tasks, the tray, Sync, first run) took it.
`BrowserTheme` now provides `onBackground` as the content color. Rows' second lines
on a dark wash were `#98989F` on a grey ground and read as dark text: they use the
iPhone's `Ink.rowSubtitle` (`#C7C7D1`, `#5A5A62`). The scheme names every role, so
nothing falls back to Material's purple baseline.

Home ("cant see a home page button"): as on the iPhone there is no such button. The
stack always shows what is open, a lone page's own card too, and leads to All Tabs
with +; closing the last card opens search at once; with nothing open the screen is
All Tabs' ground, "Tap to search" and +. A blank tab counts as nothing in front.

Pins ("always loading"): feedback 745 on the Mac, seen here. `GeckoEngine` kept six
live sessions and put the least recently used to sleep, pins included, so coming
back to a pin reloaded it. One APK, A/B (`pinback`): the old rule one page start on
return, pins held awake none. Pins of the space on screen now stay awake until
memory pressure lowers the budget (`PinnedSessions`).

The iPhone's search and spaces are ported from branch `iphone-search-sheet`:
`BrowserSearchSheet.kt` and `BrowserSpacesFoot.kt` carry its numbers. Tablets and a
wide landscape window keep their own field. Private has no lock in production
(`privateLocks = false`); the lock code stays behind that argument for its tests.
Debug builds read two emulator-only switches: `yab_capture_private` lifts
`FLAG_SECURE` so Private can be filmed, `yab_pins_sleep` restores the old rule.

## Alpha 2, published October 31

`0.1.0-alpha.2`, versionCode 2, APK SHA-256
`ae2cb33aeb2ec01f407b2c637c31ce3f98134dbd3d58e09d251951c3fa357ff1`, 160,896,652
bytes, owner signed, source `ee0c94c8754133ad55ce30c169f8cf7765577957`. All six
production stages passed in job `90c4ad1c485645ec`, device stage included: links,
search, keyboard, rotation, reinstall with retained data, production feedback and
real Mac Sync on an owned emulator. No physical phone. Live at
`/android.apk`, public bytes match. There is still no update path.

The instrumented run `bf9277ce539d4b92` left 15 suites failing, most on the old
UI's Spaces, Chats and Settings buttons and the removed Private unlock. Those
tests need updating. None of it was reviewed as a product failure one by one.

## Alpha 3, published November 1

`0.1.0-alpha.3`, versionCode 3, APK SHA-256
`7bd53edf5c1574b15ffcba1eb81c5704098b91a34e6e4ef47eac27578c0522b4`, 160,930,332
bytes, owner signed, source `1ddf522b12ad10b4d5df5fa5bc7e70510c0d530c`. All six
production stages passed in job `e981111301cc4a50`, and `alpha1-check.py` passed in
`588701ab014b4b42`; the QA message is feedback 1443. Live at `/android.apk`, public bytes
match, and `/android/latest.json` offers it. First build that updates itself; people on
Alpha 1 or 2 install it by hand once. No physical phone. RELEASE.md, "Auto-update", has
what the signed update proof covered.

## Alpha 4, published November 1

`0.1.0-alpha.4`, versionCode 4, APK SHA-256
`8eb5f6b523706f433cb9fb6c02c5f5c390db936a50fc9ec28c2a55613c098ef8`, 160,940,678
bytes, owner signed, source `53e2a6e4e58a0293124722312f0958a7f54c11a5`, job
`99a0829984b148e4`, every stage passed, real Mac peer included.

A tester reported Android saying it synced with nothing from their Mac. A device
joining a Mac with many chats redid its whole pass over every chat for each page of
the catch-up, on the thread that also reports Live, and spaces and history wait for
Live. On an emulator with `SyncLargeAccountDeviceTest` and a local Worker, 10,000
records with 600 chats went from 57 s to 37 s until Live and from 101 s to 2 s for
chats, peak heap 191 to 98 MB. The full 35,704 records with 2,300 chats, the size of
a real heavy account, now reach Live in 13 s, the browser in 4 s more, and reopen in
6 s. The unfixed build was not measured at that size: its seed ran in the same 192 MB
process and never finished. Journals now take a line per commit in a log
(`FileJournal`), and old journals open and move over. `largeHeap` is on.

Not run: the tester's own account, a phone, the live update from Alpha 3, data
surviving that update. Passwords and site sign-ins are not synced to a phone at all,
on Android or iPhone.
