# WebKit-only features on a Chromium tab

This is the historical inventory of WebKit-specific paths, not a statement
that every feature still no-ops on Chromium. Integration now implements some
of these operations through PageHandle, ChromiumPage and YabCore. The full
per-feature implementation and acceptance plan is
[evidence/chromium-webkit-implementation-plan.md](evidence/chromium-webkit-implementation-plan.md),
with exact base-source hashes in its JSON companion. All 122 labels are
covered, including remaining safe refusals and engine-neutral fixtures.
[chromium-features.md](chromium-features.md) says what is true of the features.

Yab's page code reaches a tab's engine through `PageHandle` (see
[page-engine.md](page-engine.md)). A feature still using the guarded WK path
takes its existing nil or refusal path on Chromium without constructing a
second WebKit page. The first skipped use logs:

```
YAB_PAGE_UNAVAILABLE chromium <feature>: not available on this engine yet
```

The boundary is `Sources/Fast/WebKitOnly.swift`: `Tab.webKitOnly(_:build:)`
returns the WebKit view only when the tab's page is WebKit, and
`WebKitOnly.note(_:engine:)` logs a skipped feature. Production `Tab.web` has been removed; the compatibility
accessor exists only in native WebKit tests.

To give one of these features a Chromium path, search the source for its
label below, add the engine operation (ChromiumPage and YabCore), and branch
on `tab.builtPage as? ChromiumPage` before the `webKitOnly` call, as Find,
printing and the history list do.

Chromium close/quit now has an asynchronous beforeunload transaction. The
legacy WebKit labels below do not describe that native implementation.
Unknown remote media activity still keeps a Chromium tab awake and out of
automatic agent-tab cleanup; the fixture proof must not waive this veto.

## Developer tools and inspection

| Feature label | Files |
| --- | --- |
| Native network process diagnostics | `UsageProbe.swift` |
| WebKit Inspector | `DevTools.swift`, `Inspector.swift` |
| WebKit application inspection | `DevApplication.swift` |
| WebKit developer document relay | `DevMode.swift` |
| WebKit device emulation | `DevDevice.swift` |
| WebKit inspector lifecycle | `DevTools.swift` |
| WebKit inspector picker | `DevWorkbenchBench.swift` |
| WebKit inspector state | `Inspector.swift` |
| WebKit native picker | `DevTools.swift` |
| WebKit profile cache and cookies | `DevNetPane.swift` |
| WebKit recorder runtime | `DevRecorder.swift` |
| WebKit response metadata | `DevApplicationPlatform.swift` |
| WebKit security inspection | `DevSecurity.swift` |

## Extensions (legacy WebKit extension runtime), boosts and userscripts

| Feature label | Files |
| --- | --- |
| Boost document-start registration | `Boosts.swift` |
| Boost preview | `Boosts.swift` |
| Boost preview profile | `Boosts.swift` |
| Boost report | `BoostBench.swift` |
| Boost tool runtime | `BoostTools.swift` |
| Legacy WebKit extension audio | `ExtensionTabAudio.swift` |
| Legacy WebKit extension page capture | `ExtensionPageCapture.swift` |
| Legacy WebKit extension source | `ExtensionShims.swift` |
| Legacy WebKit extension tab | `Extensions.swift` |
| Legacy extension debugger | `ExtensionDebugger.swift` |
| Native userscript fixtures | `UserscriptBench.swift` |
| Userscript document-start registration | `Userscripts.swift` |
| WebKit boost runtime | `BoostAPI.swift`, `Boosts.swift` |
| WebKit extension rules context | `Tab.swift` |
| WebKit userscript runtime | `Userscripts.swift` |

## Forms, passwords, autofill and mail codes

| Feature label | Files |
| --- | --- |
| Authenticated WebKit autofill target | `AutofillTarget.swift` |
| Authenticated WebKit form fill | `FormFill.swift` |
| Authenticated WebKit form frames | `FormFill.swift` |
| Authenticated WebKit form messages | `Forms.swift` |
| Authenticated WebKit mail code fill | `MailCodes.swift` |
| Authenticated WebKit page autofill | `PageContent.swift` |
| Authenticated WebKit wallet frames | `WalletForms.swift` |
| Authenticated credential fill | `Tab.swift` |
| Authenticated password generation fill | `ManagerSuggestions.swift` |
| Legacy password-manager unlock | `ManagerKeep.swift`, `ManagerUnlock.swift` |
| WebKit mail-code cookie context | `AgentBenchMail.swift` |
| WebKit password manager context | `ManagerUnlock.swift` |

## Media, PiP, capture and fullscreen

| Feature label | Files |
| --- | --- |
| Authenticated WebKit screen sharing | `RelayGuard.swift` |
| Camera capture control | `ChromiumPage.swift` |
| Close media presentations | `Browser.swift` |
| Display capture control | `ChromiumPage.swift` |
| Fullscreen transition diagnostics | `Bench.swift` |
| Microphone capture control | `ChromiumPage.swift` |
| Native capture fixture | `Bench.swift` |
| Native picture-in-picture return | `Bench.swift` |
| Pause all media | `Browser.swift` |
| WebKit PiP lifetime | `FloatPiP.swift` |
| WebKit document PiP callbacks | `DocumentPiP.swift` |
| WebKit mock capture devices | `Bench.swift` |
| WebKit player runtime | `PlayerBand.swift` |

## Cookies, site data, certificates and profiles

| Feature label | Files |
| --- | --- |
| Bench cookie inspection | `Bench.swift` |
| Native certificate trust | `SiteControls.swift` |
| Page profile relocation | `Spaces.swift` |
| Site cookie clearing | `Tab.swift` |
| Site data clearing | `SiteControls.swift` |
| WebKit certificate exception context | `CertificateExceptions.swift` |
| WebKit service-worker reset | `Tab.swift` |
| WebKit video-save cookie context | `VideoSave.swift` |

## Printing, PDF, archives and saving

| Feature label | Files |
| --- | --- |
| Authenticated WebKit PDF source | `PDFDesk.swift` |
| PDF export | `ChromiumPage.swift` |
| System print sheet | `Browser.swift` |
| Video save authenticated source context | `VideoSave.swift` |
| Web archive export | `PageSave.swift` |
| WebKit JSON document conversion | `JSONView.swift` |
| WebKit PDF data preservation | `PDFDesk.swift` |

## Transitions, first frames and visibility

| Feature label | Files |
| --- | --- |
| Obscured page insets | `AgentAsk.swift` |
| WebKit artifact scroll runtime | `ArtifactCard.swift` |
| WebKit first-frame scheduling | `Stage.swift` |
| WebKit first-paint scheduling | `Browser.swift` |
| WebKit mail peek transition | `MailtoPeek.swift` |
| WebKit offscreen visibility | `Headless.swift` |
| WebKit peek transition | `LinkPeek.swift` |
| WebKit scroll acknowledgements | `Tab.swift` |
| WebKit split-transition snapshots | `SplitDeck.swift` |

## Everything else

| Feature label | Files |
| --- | --- |
| Authenticated WebKit frame context | `Tab.swift` |
| Automatic agent-tab cleanup activity | `AgentTabCleanup.swift` |
| Child-frame discovery | `ChromiumPage.swift` |
| Legacy WebKit debugger cleanup | `ExtensionDebugger.swift` |
| Native WebKit history | `Tab.swift` |
| Native WebKit navigation | `Tab.swift` |
| Native editable input context | `App.swift` |
| Native history bookkeeping | `Tab.swift` |
| Native history list | `DoorList.swift` |
| Native image text recognition | `Tab.swift` |
| Native minimum font size | `Tab.swift` |
| Native page appearance preferences | `Tab.swift` |
| Related WebKit popup | `WebKitPopups.swift` |
| Restricted hover preload | `LinkCardLoad.swift` |
| Restricted iPhone read policy | `RemoteReadPage.swift` |
| Unload prompts | `LeavePage.swift` |
| WebKit agent activity mirror | `AgentTabCleanup.swift` |
| WebKit dark-mode preview | `DarkPagesSettings.swift` |
| WebKit document detachment diagnostics | `AgentBenchPage.swift` |
| WebKit document-start dark styling | `DarkPagesTab.swift` |
| WebKit feedback metrics | `FeedbackDiagnostics.swift` |
| WebKit file fixture input | `FilesBench.swift` |
| WebKit find runtime | `Find.swift` |
| WebKit history preview | `DoorList.swift` |
| WebKit image context | `ImageMenu.swift` |
| WebKit knowledge-page message source | `KnowPage.swift` |
| WebKit load verification | `Tab.swift` |
| WebKit native page lifecycle | `Browser.swift` |
| WebKit native page state | `Tab.swift` |
| WebKit navigation | `Tab.swift` |
| WebKit navigation warm-up | `Tab.swift` |
| WebKit notification source | `SiteNotices.swift` |
| WebKit notification window | `SiteNotices.swift` |
| WebKit page message relay | `StoreRelay.swift` |
| WebKit popup callbacks | `WebKitPopups.swift` |
| WebKit process warm-up | `Tab.swift` |
| WebKit readiness recovery | `Tab.swift` |
| WebKit related process warming | `Browser.swift`, `Tab.swift` |
| WebKit reload | `Tab.swift` |
| WebKit selected-text helper | `AgentAnswer.swift` |
| WebKit sign-in discovery | `AgentBenchPage.swift` |
| WebKit simulated request | `Bench.swift` |
| WebKit sleep history | `Tab.swift` |
| WebKit unload prompts | `LeavePage.swift` |
| WebKit-only bench fixtures | `Bench.swift` |

## Native parity fixtures

The native harness preserves every selected method in its inventory. Swift
Testing reports these explicit `.enabled` exclusions as skips with a reason;
a skipped WebKit contract is not evidence that its Chromium equivalent works.
The parity scoreboard annotates observed Chromium skips through
`scripts/chromium/seam2_contracts.py`. Those labels never exclude methods or
change failure, crash, missing-coverage or WebKit-baseline verdicts.
The broader [native fixture inventory](evidence/chromium-webkit-fixtures.md)
also lists explicit WebKit factories that would otherwise pass under a
Chromium environment without exercising Chromium, with a counterpart route
and prerequisite for each suite.

| Fixture | Chromium classification and reason |
| --- | --- |
| `ClosedFloatPageLifetimeTests` | Seven native callback/still tests are excluded: Browser's delayed Isolate callback, fullscreen state and PageStills cache require a WK page. The PiP ownership-state guard still runs on both engines. The Chromium lift path currently refuses the native operation; media owns the missing equivalent. |
| `PDFPageLifetimeTests` | Native PDFKit editor tests explicitly construct WebKit. Only the Done/reopen test is excluded: Browser.reopen uses the selected standard engine, and the fixture requires a native WK PDF view. Chromium PDF editing/reopen parity remains unverified. |
| `StoppedPageReplyTests` | Native WebKit control with an explicit factory, running on both ambient engine arguments: the fixture keeps an old WK document alive and explicitly answers native JavaScript after replacement. Chromium retirement closes the remote document; it cannot drive that retained-document callback contract. PageToolReplyOwnershipTests adds live current/parked/outside-owner and retired-tool/replacement-notice fixtures on the selected engine. All five actual promise cases pass on both engines in signed job 9927c33a09be4ffc, without removing the native retained-document assertions. Stopped-page metadata and refusal behavior also run in AgentMemoryStopTests. |
| `SwipeTests` | The three source/Peek/kept-Peek cases now read each engine's real history through PageNavigationList and run without engine exclusions. All 15 methods, including the three original source/Peek/kept-Peek cases, pass on both engines in signed job 9927c33a09be4ffc after the initial-fragment loading correction. Physical gesture forwarding is still navigation/owncef work. |
| `SleepFormProbeSafetyTests` | The draft/error/nonce fixture uses PageHandle in the authenticated `.yab` world and has no engine exclusion. All WebKit cases pass in 9927c33a09be4ffc; five Chromium methods fail at production activity/eligibility assertions. Those failures and every nonce/error assertion remain; native capture/PiP activity is a prerequisite. |
| `SleepLoadingTests` | All four loading-ring/teardown methods use the selected engine, including the original manual-sleep and clock assertions. WebKit passes in 9927c33a09be4ffc and f133f707e7374763. The direct sleep case awaits its actual asynchronous completion and still requires accepted=true before the original state checks. In f133f707e7374763 Chromium returns accepted=false; both direct and manual-sleep assertions remain failed. Unknown native activity is never waived. |
| `HistoryStepTests` | The original twelve timed back/forward steps beside twelve other pages loading use PageHandle and the selected engine. The WebKit back-entry assertion remains; Chromium requires a native history entry too. WebKit passes in 9927c33a09be4ffc; Chromium fails at step 2 back (22.1 seconds, native URL about:blank). All original deadlines remain; native history under load is nav/owncef work. |
| `TabEngineTests` | All methods run on both engine arguments. Explicit factories select their requested engine independently of the development override; only the standard factory follows that override. No factory-contract tests are excluded. |

HTTP(S) HTML with a base URL is implemented through `tab.loadHTML`; it is no
longer an unavailable Chromium operation.
