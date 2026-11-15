# Autofill on WebKit and Chromium

The form detector is Yab's JavaScript on both engines, with Swift owning accounts, suggestions, authorization and saving. Chromium tabs do not use Chrome's password or card store. This change removes repeated document discovery from `forms.js` and `wallet-forms.js`; it does not disable autofill, extensions or passkeys.

The completed adhd A/B observed **11.20→25.03 Chromium** and **10.00→23.43 WebKit** (three runs per condition). Chromium has document-focus warnings; WebKit is 10.90% below the same-Mac Safari control. The suspected WebKit scroll regression did not reproduce: active-gesture p95 improved **81.05→37.91 ms**. See [the final cohort and boundaries](#final-ab-on-adhd).

## Injection and native ownership

`Sources/Fast/PageScripts.swift` installs the same registrations on WebKit and Chromium. WebKit uses `WKUserScript` and `Web.world`; Chromium translates these registrations to its corresponding isolated Yab world. The page-world passkey proxies are separate because they wrap `navigator.credentials`.

| Registration | Where and when | Work and native messages |
| --- | --- | --- |
| `FormRelay.script` | Main document, document end | `forms.js` followed by `snippets.js`. Reads focused login/code fields, reports `form`, `focus`, `name`, `submit`, `settled`, code events and draft state on `yabForms`. Snippet/chat messages share this channel but are separate scripts. |
| `FormRelay.frameScript` | Every child document, document end | `forms-frame-loader.js`: one native login-field query and capture listeners. No mutation observer or full relay in editor/ad frames. Focus or submission of a login requests `load`; Swift injects `framePayload` into that exact native frame. |
| `WalletRelay.script` | Main document, document end; injected into a child on demand | Classifies card/address/form controls, reports `focus`, `fields`, `seen`, `sensitive`, `send`, answers and explicit fill/undo state on `yabWallet`. |
| `WalletRelay.soon` | Child documents, document end | One native input/select/textarea query, then only added subtrees or a focused composed target. Requests `load` once and disconnects; Swift injects the full wallet into that frame. This loader was already incremental and is unchanged. |
| Passkey registrations | Page world, document start, including frames | Forward WebAuthn through `PasskeyRelay` when offered. Otherwise the fallback lets an installed manager wrap the real page-world API and promptly rejects requests left to unavailable native handling. Unchanged here. |

`Sources/Fast/Forms.swift` receives the native `PageFrame`, rather than trusting an origin supplied in a page message. Main-document focus updates the account/code list, its rectangle and field identity; `ManagerKeep` participates on detection/focus. A child document's account belongs to that frame's HTTP(S) origin.

`Tab.sentSignIn` retains a submitted account for at most 45 seconds. Navigation or `settled` triggers `Tab.settleSignIn`; an in-place completion waits another 1.5 seconds and asks `__yabForms.hasPassword()`. A restored/rejected login cancels saving. A successful result reaches the existing credentials offer. This JS heuristic is not a server authentication verdict.

`Sources/Fast/WalletForms.swift` receives wallet messages. `load` injects the full script into that specific frame; `fields` registers split payment controls, `focus` positions the suggestion, `seen` collects the current card, and `send` starts the existing save flow. `sensitive` immediately blocks agent screenshots after number/CVC entry. `seen`, `send` and answers pass `walletTrusts`: the page's own frame, a recognized payment origin, or the current caret origin. Picks still use the existing secure-origin, authorization and native storage paths.

Apple Passwords and extension managers retain their existing integration. Filling uses each field's native value setter plus input/change events, so framework state and managers see the edit. Existing fill/save APIs, passkey proxies, native trust rules and credential stores remain. The frame bootstrap adds only a native `load` request, with the same HTTP(S) origin guard.

## What changed

At base `212d763b5` (0.46.18), password discovery enumerated `querySelectorAll('*')`, individually matched elements and entered shadow roots. The document mutation observer requested that work repeatedly, with a 300 ms stopgap. Load timers repeated discovery. The wallet's child-frame observer recollected/classified the entire document on mutations, and address-follow-up filling repeatedly queried its scope.

### `forms.js`

- There is no persistent document mutation observer. One native password query handles an existing login at load. A dynamically added login is discovered when a field is focused.
- Focus reads that field's native form or composed component. Shadow ancestors teach the detector which host types hold fields; typed selectors can then enter those known sibling hosts in composed order, including Reddit-style sibling controls. There is no wildcard enumeration.
- Submit, Enter and submit-like buttons capture the relevant login before page handlers can clear/remove it. Ordinary buttons do not submit the last focused password.
- Only after submission, observers watch that form/component and its known field roots. A formless login directly in body watches only the submitted password node, never body or the feed. They filter field/form records, stop after settlement or ten seconds, and never observe a surrounding feed to detect the entire form's removal. The short check also tests the submitted scope's connection.
- The submitted scope remains available for Swift's delayed recheck. Another login on the same page cannot veto a successful submission; a restored failed form still prevents saving.
- `email(address)` matches main commit `ee1933543`: fill only the focused editable field, refuse password fields, use the existing native setter and input/change events. `inside()`, `editable()` and `put()` remain byte-identical to that commit.
- Draft tracking uses the composed input target. Existing code, generation, overwrite guards and focus/scroll positioning remain.

### `forms-frame-loader.js` and `FormRelay`

- The full forms relay is no longer installed in every child document. A frame without a login pays one native typed query and constant-time event checks; it has no document observer, wildcard walk, input/scroll handler or positioning timer.
- A password/email/username field at load or a relevant focused field requests the full relay once, in the same isolated world and native frame. Late shadow login fields work through the composed focus target.
- Capture listeners preserve an immediate submitted password before asynchronous native injection, page clearing or navigation. The loaded relay adopts the original local submitted scope for settlement without sending the password twice. No credential copy is retained by the bootstrap after handoff.
- An ordinary editor's Enter/submit does not enumerate its controls. The bootstrap's only submission enumeration is a typed query inside a scope already known to contain a password.

### `wallet-forms.js`

- Focus and submission read the relevant form/component and known shadow hosts. Address filling stays in the focused form. Card filling retains the explicit multi-frame collection required by split payment fields.
- Child frames keep an incremental set of dirty controls and cached recognized kinds. Mutations query added subtrees with typed native selectors, filter removals/attributes and batch changed controls. An unrelated added checkbox does not re-read existing card geometry. Identical capability announcements are deduplicated.
- Reveal-after-fill uses a three-second observer on the selected form and known controls, including synchronous reveal. It no longer repeatedly queries the document on a timer and still preserves intervening user edits.
- Input, scroll and resize schedule no wallet caret frame when no list is active. Frame-wide capability refresh runs on focus, not again inside caret positioning; moving an offered card field never rediscovers every control. Existing focused-control/visible-fill positioning checks remain active only while their UI needs them.
- Number/CVC sensitivity is marked immediately from the composed target. Submit capture precedes page clearing; card/address messages keep their existing shape.

## Proof and measurement boundaries

Evidence is under [autofill-events-20261104](evidence/autofill-events-20261104/). Screening used one run per condition. The final owner-authorized cohort used three Yab runs per condition on adhd, warning-only host-load observations, and one attempted Chrome 156 control plus one Safari control.

- Swift: the latest frame-loader run passed 78 tests in five suites in `e9853b978ce0413c` (including native WK on-demand injection and a submit/remove race): `PasswordAutofillTests`, `FormTests`, `WalletTests`, `SyncWalletTests` (included by the filter), and `SleepFormProbeSafetyTests`. The new isolated-world reads use the existing callback-based evaluator. [Latest log](evidence/autofill-events-20261104/swift-frame-loader-tests.log).
- DOM: the frame-loader expansion passed all 30 real-Chrome cases in `30d6136f15674ff6`, including an idle editor frame, late login, single injection, immediate submission/removal, shadow login and the main-compatible email-only fill API. [Frame-loader A/B](evidence/autofill-events-20261104/events-ab-loader.json). The preceding 24-case suite passed in `f986ddb61ef64bdc`, including idle churn with zero document/wildcard scans, shadow ordering, focused-form isolation, accepted/rejected/restored submissions, dynamic address reveal and split-frame card discovery. The exact main resources fail 9 checks in that same A/B. An unrelated Enter workload over 20,006 elements made 400,160 selector matches on main versus 40 here (35.1 ms versus 2.1 ms in this synthetic workload). These are detector-work measurements, not Speedometer scores. [Before/after](evidence/autofill-events-20261104/events-ab.json). [Results](evidence/autofill-events-20261104/dom-final.json).
- The new [golden probe](../evals/golden/autofill_events.py) reads the prepared app's actual resources. It uses a synthetic native bridge in real Chrome DOM; it does not stand in for native account/provider acceptance. `qa/pending/autofill-event-driven.json` retains the suites, probe and matching-profile manual acceptance.
- Earlier native resource A/B checks used the same signed 0.46.15 native bundle and base/current resources. Chromium forms passed 18 cases, with one Apple Intelligence availability skip. The full baseline WebKit form run also passed 18 plus that skip. Both baseline and candidate reproduced the existing frame save-offer failure and typed-CVC screenshot assertion; these are not reported as fixed by this change. A candidate WebKit run without foreground isolation had additional UI failures, so it is retained as failed evidence rather than counted as a pass.
- Signed-in Apple Passwords/extension-manager and reporter-profile acceptance remains a manual check. Synthetic tests do not prove those accounts or the reporter's M3 Max scenario.

### Screening (different Macs, not a comparison cohort)

| Condition | Host | Speedometer 3.1 | Job |
| --- | --- | ---: | --- |
| Chrome for Testing 156.0.8078.80 | m2pro | 42.7 | `fed580e9c3c942ba` |
| Yab WebKit, optimized dev | m4 | 28.0 | `11047aeaba314542` |
| Safari | adhd | 22.5 | `869bb7858b3d4cb9` |

These nonexclusive screening scores must not be divided across hosts to claim parity. Raw reports include load, viewport, visibility and iterations. The vendor Chrome 156 archive launches normally but omits the outer resource signature file; its strict bundle verification failure is recorded, and the vendor app was not re-signed or altered.

The prepared-dev golden probe also passed all 20 cases in `b3904d7566fa40ff`. Its native GUI suites were not valid acceptance: they rejected the ad hoc input signature, and wallet cases encountered the existing protected-page boundary. The Chromium dev screening likewise failed to load CEF because the ad hoc hardened helper/framework had no matching Team ID. These failures are retained; the normal Developer ID jobs replace them.

The nonexclusive Chromium screening was also rejected for focus loss. The existing native-window readiness prerequisite is now checked before timing; focus/visibility failures remain invalid. The owner's separate per-script screening isolates `forms-frames`: disabling it gained 32.5 Chromium and 32.8 WebKit points; every other script was below half a point. These are one-run filtered three-Todo-suite screening deltas, not full benchmark scores or additive contributions. [Raw owner screening](evidence/autofill-events-20261104/per-script-owner-screen.json). This prompted the on-demand frame loader. The completed same-Mac owner-authorized cohort is reported below. Its focus/control limitations prevent a strict Chromium parity claim.

### Final A/B on adhd

Owner follow-up `.brief/say-181946.md` authorized the adhd pin and required host load to warn rather than reject. Job `adf963306c4e4567` ran the fixed signed pair in **A, B, A, B, A, B** order, with both engines in each condition. No production source changed during the cohort. The existing strict load policy remains unchanged outside the explicit `--owner-mode` / `--warn-load` switches.

| Full Speedometer 3.1 | Before, three runs | After, three runs | Mean before → after | Observed gain |
| --- | --- | --- | --- | --- |
| Chromium | 11.2, 11.2, 11.2 | 25.0, 25.0, 25.1 | **11.20 → 25.03** | **2.24×** |
| WebKit | 10.0, 10.0, 10.0 | 23.3, 23.6, 23.4 | **10.00 → 23.43** | **2.34×** |

All six Chromium scores are **observed results with focus warnings**, not strict acceptance: the benchmark's own summary is valid, but the document-focus guard caught brief losses in every A and B run. The WebKit runs passed that guard. Background load was recorded before every run as requested; this is not a quiet-host release acceptance cohort.

The single same-Mac Safari control scored **26.3**. WebKit's mean is **89.10%** of Safari, or **10.90% behind**, so the original within-10-percent goal is narrowly **not met** here. Chrome for Testing 156 failed benchmark-page readiness and produced no control score. Chromium parity therefore remains unestablished; the old controls on different Macs are not substituted.

The preparation job `f89eefef6b2b4bb4` paired the actual cached main app with the newly compiled optimized-development candidate. [Pair receipt](evidence/autofill-events-20261104/prepared-loader-pair.json) records the distinct Swift executables, identical unsigned YabCore and exact three candidate resources. Main's email-only API from `ee1933543` is included in the candidate.

[Reviewed final results](evidence/autofill-events-20261104/final-adhd/review.json), [raw summary](evidence/autofill-events-20261104/final-adhd/cohort-summary.json), [compressed complete cohort, including raw iterations and load observations](evidence/autofill-events-20261104/final-adhd/cohort.json.gz). The farm library retains the full job, 287 files / 71 MB, including movies. The job's nonzero exit retains the Chromium focus warnings and failed Chrome control; it is not presented as all checks passing.

Earlier attempts were not scored cohorts: m2's quiet checks rejected `676e342e2f5a4900` before any iteration; an incomplete transfer failed signature verification; worker Accessibility preflights also rejected attempts. Their raw evidence remains available. No system service or permission was changed, and no manual commit or release was performed.

### WebKit YouTube regression check

The same job repeated A and B with 30-second captures, 26 identical native HID gestures, the same 1000×700 viewport and fresh anonymous profiles. Gesture host-clock timestamps are stored alongside the raw SCK frame timestamps.

| WebKit capture measure | Before | After |
| --- | ---: | ---: |
| Active-gesture median gap | 21.02 ms | 19.69 ms |
| **Active-gesture p95 gap** | **81.05 ms** | **37.91 ms** |
| Active-gesture maximum gap | 202.64 ms | 62.50 ms |
| Gestures with fewer than two moving updates | 1 / 26 | 1 / 26 |
| Whole-recording p95, including pauses | 619.47 ms | 62.38 ms |
| Scroll position | 0→14,035 px | 0→14,234 px |

The reported **100→397 ms regression was not reproduced**. That earlier whole-recording p95 included the intentional pauses between gestures. Its recordings had 467 versus 475 moving updates, with 22 versus 24 gaps in the 300–850 ms pause-sized band, enough to move the p95 cut into that band. [Old pause audit](evidence/autofill-events-20261104/scroll-native/webkit-pause-audit.json). In the new timestamped A/B, no ≥300 ms moving-update gap fits inside one gesture; active p95 improves and the missing-gesture count is unchanged. No speculative WebKit code patch was made.

[Before trace and inspected images](evidence/autofill-events-20261104/final-adhd/youtube-webkit-before/), [after trace and inspected images](evidence/autofill-events-20261104/final-adhd/youtube-webkit-after/). These remain capture-update measurements, not compositor presentation fences. Live content and ads can vary, and host load was warning-only. The captured images show the target page beneath the still-raised blackout, not the curtain.

### Scroll capture

The quick YouTube WebKit trace (`97a97b66be1d4040`, adhd) recorded 30 seconds with 26 native precise-pixel, began/changed/ended HID gestures. Scroll position changed from 0 to 14,001. It captured 378 moving updates; whole-recording moving-update gaps were median 32.70 ms, p95 630.05 ms. Those numbers include deliberate pauses between gestures and are not a frame-jank claim. [Raw result](evidence/autofill-events-20261104/screen-youtube-scroll.json).

The final harness also records each gesture's host-clock interval and reports gaps within active gesture windows separately, plus gestures with fewer than two moving updates. It preserves movies, raw sample timestamps, page identity, before/after images and occlusion receipts. Input is native HID with trackpad-style continuous scroll phases, not JavaScript scrolling or a physical finger on a trackpad. SCK moving-update gaps can miss capture/encoding updates and are not compositor presentation fences or displayed-frame drop counts. X may require a signed-in profile; a login/access wall or a page that does not scroll is a failed trace, never a feed pass.

### Earlier before/after scroll traces

Job `70ddd73b957a4345` ran the signed pair on m4 using 30-second captures and 26 native HID gestures per condition. [Reviewed raw results and images](evidence/autofill-events-20261104/scroll-native/), [summary](evidence/autofill-events-20261104/scroll-native/summary.json). The job is retained in the farm library (95 files, 109 MB), including movies. The inspected YouTube images show the real page and a changed scroll position, without the blackout curtain in the capture.

| YouTube engine | Before scroll / after scroll | Median gap before / after | p95 gap before / after |
| --- | --- | --- | --- |
| Chromium | 0→12,831 / 0→14,087 px | 17.07 / 16.84 ms | 616.22 / 37.97 ms |
| WebKit | 0→14,382 / 0→14,580 px | 17.17 / 17.14 ms | 99.86 / 397.01 ms |

These are whole-recording gaps between moving SCK updates, including deliberate gesture pauses and changing live ads/previews. They are not compositor frame times, a quiet-host comparison or proof of WebKit improvement. This trace used the earlier recording harness without active-gesture timestamps; the current harness stores those timestamps for future runs.

X is **not accepted**: Chromium failed focus/page-response prerequisites, and both inspected WebKit conditions show the anonymous “Continue to X / See full profile” wall. Partial profile scrolling to 2,098 px does not prove the reporter's full-feed scenario. The current harness explicitly rejects that wall; a matching authorized signed-in profile remains pending.

### Reproducing the final A/B

`evals/speedometer/forms_dev_job.sh` builds an optimized development app through the farm. `forms_reuse_dev.py` reuses this task's content-checked optimized Swift app cache and already-built real YabCore helper, with the normal pinned CEF assembler. Input provenance/hashes are saved in [input-builds.json](evidence/autofill-events-20261104/input-builds.json). No release build or release gate is involved.

`forms_build_loader.sh` recompiles the candidate in the same optimized development mode, using the checked existing CEF helper. `forms_prepare_loader.py` pairs it with the actual cached main executable and exact main resources, updates the candidate's three JS resources, then seals both normally. `forms_final_dev.py --frame-loader` verifies the known main executable hash, permits only `Sources/Fast/Forms.swift` as a native source delta, checks exact resource bytes and identical unsigned YabCore code, and records both executable hashes. The earlier resource-only `forms_final_dev.sh` deliberately rejects this native bridge change.

A short preparation job uses the existing Developer ID identity and verifies the immutable signed pair. The scoring job needs no signing key. Normal hardened CEF requires its role-specific Developer ID signatures; no library-validation or signature guard is disabled. The default harness retains strict quiet/focus/visibility/viewport checks. The owner-authorized `--owner-mode` changes only host-load rejection to warnings, fixes the order to A/B in each round, retains completed scores separately from strict acceptance, and repeats WebKit YouTube with gesture timestamps.

The completed run was submitted as:

```sh
./farm exec --urgent --host adhd \
  --pin 'final forms A/B on the quietest free Mac' \
  --exclusive --display --needs pointer,capture,accessibility,foreground \
  --name 'Final forms comparison' --estimate 1800 --timeout 7200 -- \
  python3 evals/speedometer/forms_measure_prepared.py \
    --prepared-job f89eefef6b2b4bb4 --owner-mode
```

The separate capture-only retry `e608eac1cab44221` on the auto-selected m2 did not yield valid captures: both conditions had too few moving captured updates. It is excluded from the accepted scroll comparison; no repeated benchmark or production change followed it.

## Could Chromium's native detector replace the JS?

Yes, with a native Chromium/CEF integration, but there is no exposed `CefClient` autofill handler that can replace these messages directly. Yab already requests `CEF_RUNTIME_STYLE_CHROME` in `YabCore/src/core.mm`; the runtime choice alone does not provide a Yab-owned form-data API. The current profile preferences explicitly disable Chrome's credentials service/autosignin and profile/card autofill (`clear_data.inc`), and `AutofillServerCommunication` is disabled. Turning those preferences on would enable Chrome's own store/UI paths rather than connect Yab's stores, Apple Passwords and extension ownership.

Stock CEF does expose `CefRenderProcessHandler.OnFocusedNodeChanged` and `CefDOMNode` form-control/attribute access. That supports a limited native focus detector without a CEF fork; its DOM objects are callback-scoped snapshots, not a complete autofill/password-agent event stream.

Chromium has renderer autofill/password agents and browser-side managers. A version-pinned CEF patch or supported native adapter would need to export frame/form/field identities, origins, focus rectangles, lifecycle/submission signals and fill operations to the existing YabCore IPC and Swift relays. Swift must continue to recheck document/field identity, origin, secure context, authorization and provider ownership before filling or saving. WebKit would still need its detector. This is a separate migration with native frame/navigation, shadow-field, provider and cross-origin acceptance, not a preference toggle needed for this performance fix.

Primary references: [CEF focus callback](https://github.com/chromiumembedded/cef/blob/master/include/cef_render_process_handler.h), [CEF DOM snapshots](https://github.com/chromiumembedded/cef/blob/master/include/cef_dom.h), [CEF client interface](https://github.com/chromiumembedded/cef/blob/master/include/cef_client.h), [CEF runtime styles](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_runtime.h), [Chromium autofill architecture](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/autofill/README.md), [renderer autofill agent](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/autofill/content/renderer/autofill_agent.cc). The integration conclusion above is an inference from those interfaces and the current Yab source, not a tested prototype.
