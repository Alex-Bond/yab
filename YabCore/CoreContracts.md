# Core runtime contracts

## Verified document readiness

`tab.readiness` requires `tab`, `profile`, and optionally an exact target
`url`. It returns `ready:false` while the domains, frame or document are
unavailable, or while navigation invalidates the check. A wrong profile is
an error. A ready result contains profile, URL, main frame, default-world
context, document generation, `proof:mainFrameDocument` and
`devToolsReady:true`. CEF's raw `hasDocument` remains diagnostic.

The helper verifies Page.getFrameTree against CEF's current main-frame URL,
then evaluates a document-node/documentElement/URL proof in that frame's
default context. It revalidates tab liveness, request context, URL and
document generation across both asynchronous operations. Generation changes
on navigation, execution-context clearing, detachment and renderer crash.

The Swift client's waitForDocument has one deadline and honors cancellation.
ChromiumPage rechecks its remote tab, target URL, retirement and profile,
then includes the returned document proof with the script request. Document
scripts use the proven default-world context. Isolated scripts revalidate
the proof after asynchronous world creation. Stale proofs fail explicitly.
Low-level wire clients can still evaluate without a proof by design.

## Helper lifetime

Before CEF initializes, YabCore installs a kernel process-exit watch on its
actual launching parent. The watch covers a client that dies before socket
acceptance, and app crashes/SIGKILL even if another process retains a socket
or stdout. Socket EOF independently initiates shutdown, seen both by the
main-thread poll and by a kqueue EV_EOF watch on a utility queue. Both
watches run off the main thread and call `BeginShutdown`, which schedules the
orderly main-thread shutdown and an exit backstop (17 s), so a wedged main
loop or a browser whose close never completes cannot keep the helper or its
GPU/renderer/utility children alive. During shutdown,
new requests and late browser creations are rejected. Pending creations,
registered browsers, extra native Chrome widgets and extension content are
retired before CefShutdown. This does not use an unauthenticated PID passed
by another client, process-name matching or a system-wide kill.

## Chrome-created tab adoption

The helper emits the native tab's actual profile/privacy, real opener (when
CEF supplies one), URL and foreground disposition. tab.adopt requires that
same profile and private flag. Swift adopts the existing native browser
into a local Tab and attaches its ChromiumPage without navigating or
constructing another browser. It buffers startup state until attachment,
keeps the opener in its original profile/space, and rejects a closed or
mismatched opener. Background/parked profiles stay parked. Native close
retires the local tab; helper generations reject late adoption replies.

window.open and target=_blank have OnBeforePopup metadata and pass through
the existing WindowGate policy. Extension `chrome.tabs.create` reaches the
default client and is adopted into the space of its own request context,
keeping Chrome's tab (one document load, the same `chrome.tabs.get` result).
Public CEF does not report its requested active/index/openerTabId. Own-CEF's
native tab-model delegate supplies them in `tab.extensionCreated`. The helper
retains that receipt and returns it with `tab.adopt`, so an earlier creation
event cannot install a foreground tab before its background disposition is
known. Swift resolves its native opener in the same helper generation and
uses its requested index only when the receipt names a valid extension.
Indexes beyond the local strip are clamped to its end.

## Extension action popups

Own-CEF's `popup.layer` names the owner tab, profile, extension ID, unique
widget token, compositor context, pixel size and scale. The client hosts
that widget's layer in the existing extension-button popover. It does not
create a second page at the extension's popup URL. `ext.actions.openPopup`
runs the extension's own action API for the target page's native window;
the privileged control tab and target must have the same profile.

`popup.input` and `popup.close` carry the owner tab and widget token. The
helper resolves exactly that native popup window, refusing a different tab
or retired token. The client serializes input, rechecks the selected tab
before delivery, follows the button anchor and retires the popover on tab,
window or helper retirement. Prebuilt CEF has no equivalent authenticated
widget contract and cannot establish this acceptance.

## Native extension consent

Own-CEF emits `extension.consent` before its retained callback performs the
operation. The request names profile, extension ID and unique token; replies
must repeat all three. A stale or mismatched answer has no effect. Disconnect
drops retained native callbacks and withdraws local questions. Engine
withdrawal removes the corresponding question, and timeout defaults to cancel.

Install, permissions and re-enable questions require original manifest bytes
matching the supplied SHA-256 and Chrome's native warning text and details.
The existing Questions card preserves those strings. Uninstall uses the same
request/answer identity and needs no manifest. The app selects a live browser
of the exact profile; it cannot move the question to another sign-in.

The native question delegate alone does not provide a native install path.
Yab's existing unpacked loader bypasses ExtensionInstallPrompt. Native install
review remains blocked until own-CEF exposes a verified-CRX installer entry
point which retains the exact verified package until the answer. Parser tests
and preapproved fixture installation are not install-review acceptance. See
the core track's NATIVE-HOOKS.md for the requested API and verification rules.

## DevTools results

CDP completions run on the next main-queue turn, never inside CEF's
DevTools observer notification. A completion that sends the next command
would otherwise nest a notification and trip Chromium's observer-list
reentrancy check.

## Acceptance

`evals/chromium-core/job.sh` builds the actual Developer ID-signed app on the
farm, exercises parent death before connection and with live/unadopted tabs,
EOF, local/CWS document readiness and native popup identity, runs the
existing Chromium-tab smoke, client tests and mapped default-WebKit suites.
It writes SCK pictures and JSON. `lifetime.sh` runs only the parent-death
and EOF checks against the standalone helper, with no app build. A queued job or a compiled draft is not
feature acceptance; inspect the report and each picture before claiming it.
