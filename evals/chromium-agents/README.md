# Chromium agent acceptance

Run `job.sh` through the farm on a Developer ID signing worker with display
and capture. It builds the real YabCore and `build/yab Dev.app`, verifies
both signatures and task names, runs the original browser primitive cases,
captures the ordinary Yab window through ScreenCaptureKit. Per batch, run
`batch.sh` in a separate low-priority farm exec without display/signing needs:
it compiles the product/test sources and runs every mapped native suite through
both Swift Testing and XCTest. Native compile/tests need no special worker
capabilities and open no ordinary app or pictures. Signed windowed checks
request release-signing,capture,pointer,accessibility without a host pin.

The primitive assertions are imported from `evals/browse/prims.py` unchanged:
button, React form, editor, combobox, hover, shadow DOM, cross-origin iframe,
CSP, covered button, delayed content/wait, virtual list/scroll, drag, card
masking, reply draft, keyboard palette, offscreen rendering and CLI skew.
Two fresh MCP sessions perform button/frame actions before handing each page
to the person for its SCK picture. No further action uses a handed-off tab.

`compile.sh` only supplies early product/test/helper compiler feedback. It
executes no tests and supplies no runtime acceptance.

## Agent security inventory

`agents.frames` is separate from the lossy `scripts.frames` snapshot helper.
It returns `{frames:[...]}` including the main document. Each entry has the
same native authenticated token, frame ID, origin and URL as the script
transport. Every attached renderer's fresh `Page.getFrameTree` is included.
Missing/ambiguous default contexts, disconnected ancestry, changed sessions,
cycles, depth 32 or 256 total visited nodes produce an error. Callers must
never turn an error into an empty safe inventory.

The opt-in Chromium agent guard probes all these frames in its isolated
world, releases only a boolean and rechecks the complete token inventory.
Preflight failure and changes during an operation suppress tool output.
Extension origins (including blob/filesystem wrappers), recovery material,
private-key fields and oversized documents are refused. The probe also visits
open shadow roots, bounded to 256 roots, depth below 32 and 50,000 elements;
an exceeded bound refuses the tool rather than skipping unread content. This migration does
not change the default WebKit engine or its existing guards.

Chromium agent screenshots retain pixels in memory until a second secret
check and a matching page/frame receipt admit delivery. PNG files are written
only afterward. The safety eval includes a synthetic change from ordinary
text to recovery material after initial admission and a positive ordinary
MCP screenshot check.

For independent follow-up checks on an exact retained app, `replay.sh APP
APP_EXECUTABLE_SHA256 YABCORE_SHA256 --only iframe-user --focus --geometry`
runs the original user-owned iframe case, focused-send permission checks and
trusted screenshot-coordinate clicks at 75%, 150% and 200% native zoom. The
default replay still runs the original 17 plus security/focus. Selected cases
are recorded in its summary; a focused run does not claim a full sweep.

`replay.sh APP APP_EXECUTABLE_SHA256 YABCORE_SHA256 --lifecycle` runs the
existing agent-basics and agent-cleanup evals, each with a 600-second budget.
The adapter preserves their original assertions, uses the compiled input in
an isolated Developer ID-signed probe with `YAB_ENGINE=chromium` and
`-YabPageEngine chromium`, forwards only the synthetic fixtures' required
environment, and substitutes SCK for native winshot in the basics eval.
No new product build is needed. Results and capture metadata stay in a
separate lifecycle folder.

`from-retained.sh HOST ABSOLUTE_APP_PATH APP_SHA256 CORE_SHA256 ...` runs
through the farm when a prior job's output has been pruned. The worker copies
only the retained sealed app, then replay verifies it before launch. The
source Mac serves files only; all eval execution remains on the worker.


## Native modal questions and fixture ownership

Chromium uses nav's native `dialog.open` callback and the existing AskCard.
A held modal returns only `NATIVE_PAGE_QUESTION` with fixed person-facing
instructions. It never returns page-authored dialog text or a successful
secret check. The response deliberately has no permit `asking` flag, because
MCP's permit loop would replay the click. After the person answers the card,
a fresh guarded snapshot may read the resumed document. `native_card.py`
proves both ordinary continuation and refusal of recovery material inserted
by the click. It captures the actual AskCard with ScreenCaptureKit, then answers it with
PID-targeted CGEvent Return/Escape. The farm must supply Accessibility as
well as signing, capture and pointer; the eval only preflights existing
grants and never requests one.

The original WebKit c_dialog remains unchanged; the Chromium runner records
its native-card contract separately. Before each primitive it removes only
its isolated synthetic fixture tabs, so a previously handed tab cannot be
reused by the next case while that case assumes agent ownership. Cleanup's
MCP fixtures use a separate loopback site from the kept user tab and assert
that their actual tabs are agent-owned before measuring their expiry.

Legacy lifecycle observations and person-side chat/stop actions use the
isolated test controller's `agent-fixture-control`, not the target task's
revoked tool admission. The adapter separately checks that an ordinary task
request remains refused after stopping. This seam is unavailable outside a
test world and exposes only the existing chat, stop and state operations.


## Full agent parity sweep

`parity-native.sh` archives integration c31305f5 for the invalid-download
reservation regression, then runs the mapped candidate suites through both
test frameworks. `parity-job.sh` builds one signed input app, runs all original
primitive selections (native person-card explicitly separate from c_dialog),
URL download bytes, lifecycle, the legacy agent UIs and the agent golden checks.
Every suite has its own deadline; shared-host swarm timings are not performance
acceptance.

Runtime worlds now use the existing probe launcher to copy that compiled input
into a fresh Developer ID-signed bundle container per world. This matters:
YAB_PROBE alone does not isolate a dev bundle's default WebKit jar. The launcher
records the unchanged pre-sign executable hash and the final signed hash;
agent_launch additionally verifies the actual app and helper TeamIdentifier.
CEF's helper/framework signatures are preserved, never signed ad hoc. A world
relaunched in the same suite reuses its private bundle and cookie container.
The original built app remains the input artifact; launch-mode.json identifies
each actual runtime copy. This supersedes older claims that runtime always
launches the input bundle without re-signing.

The full-sweep adapter also replaces legacy UI winshot with PID/window-bound
ScreenCaptureKit capture, including native agent rows, faces and key settings.
It preserves each original requested path and assertions and writes
sck-captures.json. Existing window identity is read without fronting it again;
only an absent ordinary window invokes the existing readiness helper.

The plaque and face-slide fixtures use private raw bench sockets rather than
yab_socket. Their opt-in YAB_AGENT_CEF_CAPTURE=1 hook performs SCK at the
original winshot boundary, against the same PID/window, without a proxy or
caller-identity change. It leaves all original assertions intact. Other runs
keep their original capture path. The full sweep explicitly enables the hook.
