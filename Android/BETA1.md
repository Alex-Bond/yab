# Android Beta 1

Owner decision, 2026-10-28: preserve the existing app. Do not remove working
features to make a smaller beta. Mac Sync is required. AI, chats, translation
and existing settings remain. Only subsequent new features wait for later betas.
The earlier reduced-interface mockup was rejected and was never implemented.

## Release state

October 29 update: the owner requested a public Alpha first. See `ALPHA1.md`.
The previous candidate below has an empty feedback endpoint in its actual
binary manifest and cannot send feedback. It must not be published as Alpha.
The separate `0.1.0-alpha.1` producer `8ef8ac11b3f24310` supplies and verifies
the production endpoint, and requires real native feedback sending and core
browser checks. Its result is pending; no Alpha publication is claimed.

Current candidate: owner producer `f77d9b1c9a0349f1` passed all six stages on
production source `1417d562ea9763bb1b4d3f29ab4ab91237f59f6b`, farm snapshot
`e1abc795d0a61ca463d37ab1825d85aaae99b014`. Exact APK SHA-256
`a47a7db1d38f4d07ae402828c9884dab20b928c17a48cfab52dfb88a21b89ab9`,
160819360 bytes. The actual catalog contains 1190 app plus 49 core JVM passes,
zero lint errors and verified compiled native discovery. Owner signature,
production Firebase resources, R8/JNI/ELF/ZIP checks, launcher, browser/profile
reinstall and real Mac pairing/both directions/reconnect passed. This is not
complete publication acceptance. The new APK and unchanged producer receipt
are retained outside farm slots and locally in `android-beta1/owner-f77`.

The former `766e59...` APK must not be published. Its public UI revealed an
input character loss and a regional-locale translation failure. Commits
`a565d8ea8`, `02a291a0a` and `dd6ee1337` fix stale native field echoes and
ML Kit language normalization. Real MainActivity before checks failed; after
`1f00641ef857458e` passed the unchanged assertion with requested `en-US`, actual
`en` and source `pt`. Owner-APK download/inference/restoration still needs its
separate public UI run. Six new JVM regressions passed in the current catalog.

Owner decision, October 29: retain the existing Extensions screen if it works.
Its entry now uses the existing foreground/public page menu and is suppressed
in private contexts. This mobile page-scoped management route is intentionally
excluded from the Mac `Command` catalog; no Mac menu/action was added or renamed.
The native signed package's consent, public content effects, private exclusion,
fresh-session activation and uninstall require actual owner-APK frame review.

The public UI suite checks settings, browser, translation and extensions in one
owned installation with real process restarts between scopes. Each failed scope
is retained and does not manufacture passes for later scopes. Real Mac tabs,
pins/folders and production background FCM follow; real official Codex recovery
and native approval decline run separately on its existing signed-in host.
Complete current native inventory is also queued. Older passes below describe
their original artifacts, not acceptance of this rebuilt owner APK.

- Owner decision, 2026-10-29: the owner will release Mac himself. Preserve
  the prepared compatibility source and proof in separate owned commits;
  do not run a Mac release or silently remove required Mac Sync. After the owner
  delegated the remaining work, the exact tested production patch landed on main
  as `8b529b5268f32a79b38c0c30e80ad641e7336b7f`. No Mac release or push occurred.
  Public Android acceptance still requires a compatible public Mac client.
- Existing app features and Mac Sync remain in Beta 1; no reduced UI was applied.
- Complete baseline 47ffe04e1f6f4ad2 / c971da6edc0e passed 1,233 JVM
  results, lint/DEX discovery and all 241 native methods in 95 classes on the
  owned API36 ARM64 emulator. A later genuine signed-extension check exposed
  one installer activation defect, which was fixed and natively proved in 5831.
- Retained test-signed candidate: 10a42d16c70a49cf / 76d704695a43. The guarded follow-up
  verified all 534 production paths against the passing signed-extension source;
  the installer is the sole production difference from the complete baseline.
  New R8/JNI/ELF/ZIP, fresh install, same-version profile-preserving reinstall
  and real Mac Sync both ways/reconnect passed. No new full 241-case run is
  claimed after that isolated fix. This is a test-signed APK, not public release.
- Retained local test APK: 160,812,868 bytes, SHA-256
  9c4095e3eb45026fbd1e6778c2abc5c6640c16dbcc9b7d7d90706e4cecde5c29.
  Path: Documents/Codex/2026-10-28/android-beta1/yab-android-0.1.0-beta.1-test.apk.
- The latest focused source has passed all six motion/workspace cases; the prior
  36-case wave passed 35 and exposed only the corrected input-timing fixture.
- Production Sync Worker supports Android; the isolated current Mac companion
  passed 60 tests. This does not publish a compatible Mac app for end users.
- Publication is incomplete. The permanent owner key was created after explicit
  delegation, with its password in main's login Keychain and a verified encrypted
  key backup on renderer-2. Production Firebase and the Sync Worker's least-privilege
  FCM sender are configured. The client key is restricted to `dev.yab.android`
  and the owner's release certificate. Actual production background delivery
  remains pending. Real Codex chat/reconnect passed against the exact debug
  APK in baef3ad9a05c4550; real provider approval decline also passed in 8ebe8d0b031b40ba.
  These are not owner-signed/public-release acceptance. The isolated SDK on
  already-signed-in Codex worker adhd passed actual HVF/guest preflight.
  Existing renderer-2/m4 have no official CLI.
  No sign-in or credentials were moved to work around that boundary.

## Owner-signed production artifact, 2026-10-29

- `2b4d38a462f74d43`, frozen source `a595d4d8ae22cdc162db92e91930ab67d40c9314`,
  verified the same 534 accepted production inputs. All 1,233 JVM cases, debug
  lint, compiled native discovery, the independent Swift Shield oracle, release
  lint, R8, actual owner signature and 21/21 native ELF alignments passed.
- The actual owner APK is 160,817,104 bytes, SHA-256
  `766e59cdf570d875d9d42b7cf4310f2da3ddcfa83acc62c2b2cffffa170ad52e`.
  Certificate SHA-256:
  `59ae46a10f4b2e1ff3b2ffd8de63b82cbe603efda34a3195f537fafaaba33ada`.
  Production project/app resources were inspected in those actual APK bytes.
- The producing job stopped at a harness filename error: catalog output uses
  the task name, while the next verifier looked for `app-debug.apk`. The failed
  original receipt is retained. Catalog selection now requires exactly one
  ordinary, non-test APK, refusing ambiguous files and symlinks.
- No-rebuild `3e143f735918413c` / `97cb92fefe7f` passed static JNI/layout,
  first-run, browsing and profile-preserving reinstall, then Android displayed
  `Pairing server`. Its failed receipt is retained; the cause was not established.
- No-rebuild `a63c7efce38d4fde` paired on its first invitation and passed both
  actual record directions. It acquired a genuine production FCM token and
  completed token registration, but background delivery timed out. That failure
  occurred before its reconnect check, so reconnect was not accepted there.
- `24fa63d0adf540e2` / `c3583a07628e` passed the exact owner APK's full basic
  smoke, same-version profile preservation, real Mac pairing, both directions
  and reconnect. Its crash buffer was actually checked: no crash/ANR. FCM still
  failed: no new FCM work, no new journal cursor or marker while backgrounded.
  No local push or private-data mutation was used. Disposable Mac Sync was off
  and the owned emulator was destroyed afterward.
- Sender configuration was reapplied from the original production service JSON
  through a fresh standard Yab MCP connection after the owner authorized a
  reconnect. The RSA PEM and escaped-line round trip were validated without
  printing private values. Worker deployment `c83fd924` is active; health retains
  Android Sync v1. Delivery repeat `244e2fc217eb400c` is running, not accepted.
  No new complete 241-case native run is claimed.
- The publicly downloadable Mac Nightly 0.42.1, build 202610281859, was traced
  to prepare snapshot `00159557ba03dee9d9dd557f28e298d2e9d71bb6`. Its source
  neither advertises Android Sync nor recognizes the Android mobile capability.
  The owner will publish the compatible Mac; Android publication remains gated
  until a compatible public Mac exists. No features were removed.

After accepted Beta 1 is published, retain its exact APK/source/signing identity.
Subsequent features enter the next version individually with their affected
regressions. This task has not started a later feature or removed an existing one.

## Provider QA setup history

- Existing official Codex on adhd was checked through its own login-status command,
  with output discarded: signed in. Claude was present but did not report a live
  sign-in; no login was attempted. adhd has over 58 GiB free before setup.
- Named farm job 54dd35dbc8154a04 passed isolated SDK setup and the actual
  official HVF plus ARM64 API36 guest preflight on adhd. Only the two already-accepted, pinned
  license acknowledgements were copied from the existing SDK; no new terms,
  credentials or provider configuration were copied. The farm still controls
  power/display admission, main remains excluded, and blackout remains raised.
- Android scripts now support adhd for this queued native QA; the real worker
  marker is mandatory. Four offline worker/license/HVF guards passed.
- A retained current APK pair is bound to producer ea93994d8c8d4c84 / snapshot
  2a5b9ee403c07bc2a03d67e3c7879d9c66c52346. All 867 compiled app/test/contract/
  Worker source files were compared with the frozen Git tree, not the lane's
  older HEAD. The provider wrapper verifies the same source inventory and exact
  APK hashes before reuse; seven tamper/missing-source guards passed.
  At that setup checkpoint real provider answers had not run; the later receipts
  below carry the actual provider acceptance.

## Retained native and provider evidence

- Full wave ea93994d8c8d4c84 finished: 241 expected/reported, 240 passed,
  one Reports fixture failure, no missing methods. It did not reach R8 or new
  Mac pairing. Evidence SHA-256:
  47f95eae8d0dbac680afe69b114fa2eed318b111120186b8c9c3fb3de6b628c8.
  Reports awaited two controls, then reread a transient IME root and got an
  empty list. The fixture now retains the original admitted native input/button
  and performs it once. Reader + both Reports cases passed in 444ae026eeba4ad7.
- RealTranslationDeviceTest passed in efa00c5991ca4183: actual ML Kit language
  identification, PT language-model download through the shipped native dialog,
  genuine native translation, real Gecko DOM update and exact original text
  restoration through Show original. No translator response was substituted.
  The actual translated screenshot was read. This explicit network test remains
  compiled outside the ordinary 241-case inventory; ten selection guards passed.
- Isolated real Google FCM passed in 54124e36d8a245d1, snapshot
  df5b80b0d120c8d45b3bbd048f26acbe51e28552: four accepted Google sends and
  four observed native stages, including production WorkManager outcomes.
  Exact root/native receipts and cleanup hashes were checked together in
  fcm-5412-accepted.json. No production sender credential was verified, no
  physical Doze/cold-start claim or per-Google-message/work-request linkage is
  made. An earlier attempt 89758a42964249cf missed the root sender window and
  failed; it remains retained as failed. The repeat's sender was attached as
  soon as the immutable native identity existed, before the first offer.
- Full 21b1897ed0ea4737 finished with 241 expected/reported, 240 passed,
  one Reports fixture failure, no missing methods. Both new form fields were
  empty after ACTION_SET_TEXT had returned true; the fixture had swapped
  controllers within the same Activity instead of recreating the screen.
  It never reached R8 or new Mac pairing. Archive SHA-256:
  4e763b77098c13e9463b39b93018bf677c1bbf61e5be73f3c4982c59a2c0abbc.
- The fixture now really destroys/relaunches the Activity, proves the original
  host was destroyed, and captures the editable control by its exact field label.
  Reader plus both Reports cases passed in 3ddfc6def9744591, including actual
  draft, consent persistence and the local transport assertions. Archive SHA-256:
  5cb8ff45b053b3ecaafe51bbbe31cef66322ed8c1ff3370f0ab669447f12222b.
  The production report UI was not changed by these fixture corrections.
- Baseline 47ffe04e1f6f4ad2 completed all ordinary native cases after that
  Activity-restart correction, followed by new R8/layout/reinstall and production
  Mac pairing with the accepted a77 companion. Every stage passed.
- Provider jobs 51074e69569c4fae and e82bd4b998a04123 failed before bench
  readiness or provider invocation: Darwin refused their too-long Unix socket
  paths. Their failed receipts are retained. Original PIDs 12266 and 15036 were
  absent at a later read-only ps check; no signal or deletion was performed.
  The next harness uses ap- plus the complete UUID32 and byte-checks sun_path
  including NUL before any world/AVD/GUI launch. All seven provider guards pass.
- The minimal a77 compatibility binary has no provider-proof bench hook. Do not
  run the provider wrapper against it again. Existing guarded hook/source-only
  login/config protections were restored from historical 3e121213 into the
  separate Mac companion checkout, preserving other current production code.
  Build 8022f6fcd1194950 passed all 62 tests in nine suites: the 60
  compatibility/account-entry tests plus two no-config guards. Raw Fast SHA-256:
  2798ee9d7de85041318134f1b8ab3f68071ce907629a13028508064a7daaf6c3. Ordinary production runs
  do not enable these hooks; a compatible public Mac app is still unpublished.
- New provider Android inputs are bound to 47ffe04e1f6f4ad2/c971da6edc0e:
  all 868 compiled-source paths match both its frozen Git object and actual
  running lane bytes. APK SHA-256 remains
  346bd732c5f800e3bb94e78af442f86a93045bc9736d8f5de7602bf51ea9352a;
  new instrumentation SHA-256 is
  b972736c552b1d8ef9e1119c278f979956969de49b458a871856c5c9e119a109.
  These do not acquire a provider pass until the actual scenario runs.
- Publication now requires six explicit checks in addition to the original ten:
  real downloaded translation model, real provider reconnect and approval
  decline, production FCM delivery, publicly available Android-compatible Mac
  and actual signed extension installation/content script/private isolation.
  Passing debug/test-project QA does not set those exact-release checks.
  All eight publication guards plus two upload-route guards passed offline;
  their synthetic fixtures do not constitute release acceptance.
- Actual provider job baef3ad9a05c4550, snapshot
  31642f0e181aac63930a5fde9c8f471f202fad0c, passed the genuine two-turn Codex
  conversation across Android adapter/Keystore/journal reconnect. Both traces
  identify the same real provider binary/session/thread. The second question
  did not resend the random token. Production provider teardown was confirmed.
  An actual parent/TERM-ignore-child fixture plus independent surviving sentinel
  passed before the provider run. Exact Android producer remains 47ff/c971;
  actual new Mac QA producer is 8022/fb013. No login/auth/config was transferred.
  Root accepted receipt: provider-baef-accepted.json; raw proof SHA-256:
  f398cfaecbcc49e7f7303044140fdc156f28f39f4805bfbf71e1506f832db554.
- Real provider approval-decline passed in 8ebe8d0b031b40ba, snapshot
  755a19983deec405553cea04f54089f27d606902. The actual issued sealed question
  was declined by native pointer DOWN/UP; all seventeen original owner guards
  stayed true. No direct controller answer or AX click was used. Android No and
  exact Mac consumption were observed, the disposable form had one read and
  zero commits, and two genuine replies resumed the same provider thread across
  Android reconnect. Original provider teardown and independent cleanup fixture
  passed. Raw proof SHA-256:
  b77db1a740a6b924137abebf2627680b17d08ae3f77142e06c6842c0c0f2817a.
  Native pointer receipt is retained in provider-8ebe-native-action.json.
  This does not prove biometric Yes or physical hardware.
- Signed Mozilla XPI acceptance is explicitly tested outside the ordinary
  native inventory. First c207809552594dc5 failed at a fixture text-leaf Cancel
  click; after selecting the original owned clickable native parent,
  1d525d8896fd42d4 passed Cancel but timed out waiting for native installation.
  Neither failed result was accepted. A fixture-only follow-up de91cb1d00ac4365
  waits for the original dialog's actual native window dismissal before the
  second install and asserts a fresh window. It then proved the package was
  installed as version1.0 with no error but enabled=false. That is the actual
  installer defect, independent of the earlier fixture targeting problems. The earlier discovery reason incorrectly
  said next release; current wording explains its real external fixture/network
  requirement. The feature remains present. No external pass is inferred from
  the ordinary 241-case batch; ten selection guards passed.
- The installer now awaits the native Private restriction before enabling the
  explicitly accepted install through Gecko's USER route, then updates the host
  and UI from the returned enabled/private-off object. Native errors are retained;
  signature validation and consent are unchanged. The current [GeckoView API](https://mozilla.github.io/geckoview/javadoc/mozilla-central/org/mozilla/geckoview/WebExtensionController.html)
  documents this activation route; actual runtime acceptance used pinned158.
- 58310a0ba015420b / 37d713a4563fdbb5abfa58e33364872ea8a22c27 passed
  JVM1,233/lint/discovery and the genuine signed-extension scenario. The exact
  native test source is identical to failing de91 (SHA-256
  82aa92d4fd2c2c04b2a1a495625bcf79fde0455ef84be4d41ea6b5d7ffbde7f6).
  Verified: real Cancel/fresh Add, Mozilla signed/not built-in/not temporary,
  actual red content script, Private exclusion, fresh native session and uninstall.
  Consent, content-script and uninstall images were read. Evidence archive:
  1ca70069889f97d8690538a2790e6a89e699cd2bde9f6c16155b6c0faed3822c.
- 10a42d16c70a49cf passed the scoped new R8/layout/profile/Mac refresh after
  that fix. It retains the 241-case baseline and actual new signed-extension1
  separately, guarded by unchanged production inventory plus the sole installer
  delta. R8 smoke archive SHA-256:
  0e3dfa4e9f0d3b06353f990e9550dbcd9358b636e445b85ca7d16bf5b71e92fd.
  No Owner signing, production Firebase, public Mac or website download is
  accepted by this scoped QA result.
- Public Mac compatibility is prepared as mac-public-android-compatibility.patch,
  twelve exact production/test paths matching the accepted a77/60-test source.
  It excludes the provider QA hooks and applies to committed main
  1fa5381b358743b45275a2462026eab1d66380ec in a disposable index. No user
  index/worktree was touched; no manual commit, push or Mac release occurred.
- Full final proof 47ffe04e1f6f4ad2 passed every stage. Its 241 native methods
  in 95 classes took 2,128 seconds; JVM 1,233/lint/DEX inventory also passed.
  Exact test-signed R8 APK: 160,812,608 bytes, SHA-256
  607123da8b24124007240dca98c54696ff020683c79808ce93a77fda0d1f850d.
  Actual R8 profile update is a same-version reinstall, not a previous public
  version upgrade. Native proof archive SHA-256:
  de1dcd635ed047e40d4e3d671d9f3d4311630b7bcb0db20db6fe70cd3d081347.
  Separate R8 smoke archive SHA-256:
  3f2985c62d5a4a8a5047cdba243d5a734f49e46f32c6911d6492227732e72723.
  Actual reconnect screenshot was read; all three Android/Mac/reconnect rows
  are present. The disposable Mac Sync account was switched off on cleanup.
- Default owner signing-key metadata was also checked on adhd and m4: absent
  on both, as on main/renderer-2. No password/key content was read or generated.
- Focused Beta checks now use the same beta versionName/versionCode as full
  qualification to avoid needless alternating BuildConfig recompilation.
  No additional build was submitted just to verify cache reuse.

## Latest checked results, 2026-10-29

- Full native wave cda2358febbf42cb: 1,233 JVM tests passed, no failures,
  errors or skips. Native: 240 reported, 212 passed, 28 failed. Failures and
  original class logs are preserved, including the unchanged passing lifecycle tests.
- Finishing wave d81ecc1c03754fe3, snapshot 03544bc77a962c78fcfab40e0a4c020fc33eb49f:
  compile/JVM/lint and R8 passed. The exact **test-signed** release APK SHA-256 is
  20c616134d52c246e675eff3a292f79d2ec1cb3a19aa3adc56e2368e6f52ec1c.
  Fresh first run, browsing, saved tab/cookie/localStorage surviving reinstall,
  real production Mac pairing, matching digits, both record directions and
  Android restart/reconnect passed. Actual emulator screenshots were read.
  This proves the preserved compatible Mac binary, not a public Mac release.
- Its focused native result is **not accepted**: 96 expected, 91 reported,
  74 passed, 17 failed, 5 missing after process crashes. In particular the
  image-download revocation case still crashed in Gecko's native port teardown.
  Current source extends the retirement fix to page/image/preview bridges;
  four shipped-JS guards pass, three failed on that frozen previous source.
- Follow-up 2852093fbb6c4437 uses snapshot e0ad5c2f576fc78f47f11b7c2b14dbbe1165bd14
  reported all 44 selected native cases: 30 passed, 14 failed, none missing.
  All four image-download cases passed, including native teardown/revocation;
  both page-download cases and all five lifecycle cases passed. The destroyed
  native prompt regression passed without the old WindowManager crash.
  Its static R8 stage was refused by the old compressed-library inspector before
  JNI comparison; it is not a JNI failure or a passing static check.
  Follow-up source fixes are not proved by this earlier snapshot: Compose stable
  1.12.1 for hosted AndroidView Autofill traversal (Material3 remains 1.4.0),
  native screen-origin publication, fresh chat/settings view leases, serialized
  AtomicFile report reads/writes, and corrected media diagnostic forwarding.
  Native camera consent was actually drawn; its buttons were uppercase, while
  the fixture incorrectly required title case. That selector is now scoped to
  the actual native Button class and exact words, ignoring only case.
  Gradle project history now lives outside snapshot-cleaned checkout, isolated
  by canonical physical project path; two migration/isolation guards passed.
  No new build is run solely to collect cache statistics.
- Follow-up 59e79c83027149d4, snapshot ab8093b18d1b7bfb4d185a8750f299953e035be2:
  static inspection of the exact retained R8 APK passed (including 76 required
  LiteRT JNI methods), and current compile/JVM/lint/discovery passed.
  Native: 44 expected, 42 reported, 32 passed, 10 failed, 2 missing after a
  media-class crash. This is not release acceptance.
  Chat return, page reload, preview, report consent persistence and all five
  Gecko lifecycle cases passed. The image revocation cases remain passing.
  Autofill still received only two structure nodes: the programmatic GeckoView
  also needs explicit IMPORTANT_FOR_AUTOFILL_YES. This is now in current source,
  with bounded native ancestry/service shape diagnostics for the next run.
  Media playback/metadata/position were real, but no initial Features event came
  from pinned Gecko 158. Its native MediaController starts with six default
  transport keys and the bridge only publishes later supportedkeyschange events.
  Current source seeds exactly those native defaults on real activation, retains
  explicit native feature updates, and never invents next/previous actions.
  Remaining current changes are unverified until the next frozen run: original
  immutable app callback capture through Compose's public tooling API (no catch
  or discarded assertions), a fresh Done action node per settings edit owner,
  pre-press dialog geometry settling with unchanged source/window/UP guards,
  native result Button case matching, and awaiting the real Private Back URL.
- Wave 54f99f5f95a44bc3, snapshot 886d4776f6042acfbc89972a13027cbd578da938,
  stopped before native tests: 1 of 1,184 app JVM cases failed because the old
  farm-cda Shield oracle path had been pruned. No native result is claimed.
  Native source compilation had succeeded; test APK/lint stages were not reached.
  The oracle was absent from the locally retained native archive too. Current
  runner recomputes the small two-Swift-file oracle in its own job instead of
  depending on the old job directory. Exact d81 APK inputs are separately retained
  under the worker's yab-android input directory, with their original hashes.
- Wave 961a62d88c234348, snapshot d2b37e5ab5bf (full id in the farm receipt):
  fresh shared Swift oracle, current compile/JVM/lint/discovery and retained R8
  static inspection passed. Sidebar (2), page downloads (2), Back history,
  space editing (3) and preview passed. The complete run is not accepted.
  Actual AutofillService now received both HTML inputs and filled the username
  and password; its later web-button lookup still used Android's incomplete
  indexed query. Current fixture walks the real owned tree for that button.
  Real media Pause/Play/Seek progressed to the Home return: the fixture copied
  ActivityScenario's CLEAR_TASK flag and destroyed the task it meant to retain.
  Current fixture replaces those flags and retains the same-Activity assertion.
  A real Private capture lock exposed a cookie handoff race: the last recording
  page closed before the new RAM keeper acknowledged. Current production source
  starts the keeper when the first Private page is created; the regression also
  requires it to be naturally ready before capture and still verifies immediate
  OS camera/audio release. These newer changes are not yet native-accepted.
  Native result matching succeeded, then ActivityScenario.recreate tried to
  force RESUMED under the real external fixture. Current test recreates only the
  exact stopped Main under its own focused same-task result activity, preserving
  task/store and result-rejection assertions, with no forced foreground change.
- Wave e1e9a5d690744f79 (snapshot 98d1ed6d04bc): fresh Swift oracle,
  compile/JVM/lint/discovery passed. Private capture now passed end to end,
  including RAM cookies, actual OS device release, fresh consent and native Back.
  All five Gecko lifecycle cases and both WebAuthn native cases passed.
  The remaining failures are not accepted: Settings About Back readiness,
  first Autofill request setup, and two PiP returns which recreated Main.
  Current source adds screenLayout to Main's handled configuration, matching
  Android's PiP manifest guidance, while retaining same-Activity/session checks.
  Source after this frozen wave also waits for the app-side Autofill manager
  and fully opened Settings presentation before driving their real controls.
- Wave b720534eece74445 (snapshot 9145daf10c79) stopped in instrumentation
  compilation: the new Autofill readiness lambda needed a suspending predicate.
  That fixture signature is corrected in current source. No native case ran.
- Wave 4fcd1982660c4f0c (snapshot bdee7c1023a7): fresh Swift oracle,
  compile/JVM/lint/discovery and retained R8 static inspection passed.
  All nine selected native methods reported: seven passed and two failed.
  All four media cases passed, including both actual system PiP returns to the
  same Activity/session, public background audio and private metadata policy.
  About failure was a wrong test expectation: direct About is its own root
  (already required by SettingsPresentationTest), with Close, while the test
  selected the covered page's Back. Current fixture selects Close strictly in
  settings.header and requires the whole sheet to disappear and PAGE to return.
  Autofill still made no provider request despite an enabled app-side manager.
  Its framework diagnostics are retained; current fixture prepares an actual
  native finger tap on the form's exact owned HTML label instead of relying on
  accessibility focus alone. Positive values and all stale/container/Private
  refusal checks remain required. Local evidence archive SHA-256:
  e911c2fe96d05ffe12a3750857d87014196e7b62119e698345588331bfbbcf0e.
- Wave d3908d2b97d24684 (snapshot 58b0535ba24a) checks the corrected About
  close and HTML-label activation: all four Spaces tests passed; Autofill still
  failed before its first dataset. The real system diagnostic has no session,
  request history or provider callback, despite the selected/enabled service.
  No filled-value acceptance is claimed. The explicit physical-tap helper and
  delayed public PiP frame captures were added after this freeze for the next
  required native run. A first transition-black PiP screenshot by itself does
  not establish that video pixels are presented.
- Wave 6ab2d7f1f7f74463 (snapshot dcb039bfbfcdb9e6fb0920d54475b4462cf3ea14):
  all stages passed: fresh Swift oracle, compile/JVM/lint/discovery, retained R8
  static inspection, and all five selected native cases (Autofill + four media).
  Actual native tap produced provider FillRequests. Complete filled values,
  second-container isolation, stale dataset refusal across a container change,
  locked Private refusal and fresh post-unlock fill all passed.
  Three delayed actual public PiP screenshots were read: the Mozilla fixture
  video is visible and changes across frames. The original black frame was
  captured during the system surface transition. Public fullscreen and actual
  filled-form screenshots were also read. These are owned emulator fixtures,
  not real customer/provider accounts or physical-phone proof.
  Retained evidence SHA-256:
  c6075f7198e6ed309949d9ae4395f97866346ea8d1969636e3bfe49ca9a5fb66.
- Full current native inventory 81fadd2bc8234498, snapshot 6566a00cb239,
  completed with 241 expected/reported, 228 passed and 13 failed. Its catalog
  stage is **not accepted**:
  macOS Bash 3.2 aborted an empty optional array expansion, yet returned zero
  before Gradle was invoked. The later native runner did compile both current
  debug APKs normally, so its actual device results are retained separately.
  Verified evidence archive: native-81fa-evidence.tar.gz, 1,067 files, SHA-256
  8f3d83a2e2942cb1c96145b140affbf9a6f4d826663b628643d8b2094d405fec. Any automated overall success on this old runner is
  insufficient for acceptance. The newer catalog uses positional arguments;
  both runners verify actual current-job JVM/lint/discovery reports as well as
  the shell exit code. Six shell/report regression guards passed locally.
  The external Swift oracle is now an explicit content-based JVM Test input,
  so changing/removing it cannot silently reuse an older job's test XML.
  No app feature/source changed for these runner corrections. A passing full
  native result may be reused only with the identical compiled APK pair and
  explicit source/proof identity, never by assigning its result to new bytes.
- Subsequent source after the 81fadd freeze is not yet device-accepted:
  remaining retained click probes (payment chips, first-run, Field chats,
  private rows, tablet address/settings) capture their original immutable app
  callback, including public selectable tooling. Fresh successful controls still
  use the actual native paths and every stale-action assertion is retained.
  Gallery replacement now explicitly recreates its real Activity: the PiP
  screenLayout fix legitimately made resize alone preserve it. Workspace editor
  readiness captures one original Field lease after its actual host resumes;
  source tab/profile/epoch guards remain mandatory before and after admission.
  Parked flick checks the existing absolute-speed gate (actual recorded speed
  was -2957 points/s with a 90-point drag); original direction, sub-110-point
  distance, flight ownership and deletion timing remain asserted.
  Emulator compilation now matches catalog ARM64-only inputs, avoids retaining
  unused x86_64 libraries, and records both compiled APK hashes in normal results.
- 81fadd also exposed a genuine late Autofill delivery at Private lock:
  the fictional private form contained fixture-private before the required fresh
  choice. The earlier focused pass did not establish race-free behavior.
  Current candidate binds framework structure/fill to the original native
  entry, document, view, foreground and Private lifetime; Private lock cancels
  the old OS proposal synchronously and invalidates its receipt before Compose
  can remove the view. Ordinary live native fill remains required. This newer
  candidate compiled in wave 550c8b7a8abb493c (snapshot
  016c340b3800bdb9a1b64e1233ee3b801fa47e89), whose catalog reports verify
  1,184 app and 49 core JVM tests, zero lint errors and compiled discovery.
  Its native Autofill scenario passed, including real SDK dataset authentication
  Activity return to the original public form, first/second containers, stale
  proposal refusal, locked Private refusal and fresh post-unlock fill.
  All 36 selected native methods reported: 35 passed and only the old
  timing-distorted parked flick failed. Reader exact restoration, both report
  cases, all five lifecycle cases, all four media cases and actual Private
  capture release passed. No crash or missing test was converted into a pass.
  Native APK pair SHA-256: app
  3001bdc4a5e624b9639091ebeda1b11da078adcd33d42353b593eac26479cb40, test
  35117c09ce3bfaf811a0df3f51f83015f20e55ad099ee3ba5866f5fb91eb2ac5.
  Evidence archive SHA-256:
  f183dd3b9679a6b34ff52daa19639909a82c9e3391203ef5233eda0f1e6e5b93.
  All four workspace menu cases passed in that wave, including the original
  compact-to-tablet Field text/selection/IME scenario; a complete repeat is
  still required. The temporary field-exit observer was removed afterwards;
  the complete repeat must pass without it. Both payment cases, first-run and all three tablet-toolbar
  cases passed. The native short flick still failed: real root-tree IPC made
  its UP arrive 28 ms after the last move. The newer fixture checks the same
  native decor window ID, focus, source, bounds and origin on every sample
  without a repeated remote tree traversal, using actual event uptime.
  Wave b24002f2325c487b stopped in test compilation: the initial direct View
  window-ID accessor is not in the public SDK. Current fixture obtains the same
  actual window ID from decor.createAccessibilityNodeInfo(), recycling the
  original local node immediately; native tests did not run in b24002.
- Wave f1ab6f72359c454a, snapshot 442071305722: all stages passed,
  including 1,233 JVM tests, lint/discovery and all six selected native cases.
  The actual 90-point flick reached LEAVING with the original chat present;
  recorded native events used actual uptime, with UP at 19 ms, and the real
  tracker speed was 9,946 points/s. All four workspace-menu tests passed
  again without the temporary field-exit observer. This focused repeat does
  not replace the required complete 241-case run on current source.
- Mac companion based on the dd73adf8 main snapshot is isolated in the managed detached checkout
  ~/.codex/worktrees/android-mac-companion/fast on dd73adf8, preserving the newer
  Turn On Sync account-entry fix. Only Android compatibility consumers were
  applied; unrelated Journal changes were excluded. Test job a77acbb0920f45d1
  passed **60 tests in 9 suites**, including all six newer account-entry regressions.
  Preserved executable SHA-256 f819a786b8fc382552a0b0f846faf635a00af69cb0fb72f9a7b672568138eacb;
  snapshot e6ed1ee3738ce1ac78c967ffee399a1884fc8b58. Its 83 PageScripts/Skills
  resource files are bound to that same snapshot. No Mac application was published.
- Read-only production readiness check on 2026-10-29: yab-sync has no
  FCM_PROJECT_ID, FCM_CLIENT_EMAIL or FCM_PRIVATE_KEY secrets. The visible
  Yab cloud projects include only the isolated Android test project plus
  unrelated Drive/Mail projects. Production Android push remains unconfigured,
  not merely untested. No credentials were read and no cloud settings changed.
- No owner release signing key, public Android APK or download route has been
  created. The test-signed APK must never be uploaded as the user release.

## Frozen candidate

- Version: 0.1.0-beta.1, versionCode 1, same release package dev.yab.android.
- Active detached managed checkout: ~/.codex/worktrees/android-beta1-emulator/fast.
  Recovered the frozen input after the old manual worktree became unreadable.
  No branch switch, manual commit or push. Primary dirty checkout is untouched.
- Existing Android/SharedContracts and compatible SyncKit/Worker sources were
  copied explicitly; original dirty main and other sessions remain untouched.
- Previous qualification 5789f8c7d10f4613, frozen snapshot
  7fab3dc7b4f38c1922ba286f899bdc13c4ea11e6, failed in test APK compilation:
  MixedKeptTreeDeviceTest imported AppFlowTest from the wrong package. App/JVM
  stages ran before this failure; native tests and later stages did not run.
  The complete original log is retained in the Android Beta 1 artifact folder.
- The runner compiles app/core tests, debug APK and instrumentation APK, lint,
  exact native test discovery and compatible API36 device tests, then R8 release,
  signature/alignment and release launch checks, plus Mac Sync compatibility suites.
  Current default native inventory has 241 source methods;
  external real providers, FCM and paired motion retain separate proof requirements.
  They are not synthetic passes. Physical-phone coverage is neither required nor claimed.

## Required acceptance before the site download goes live

1. Current exact-source compile/JVM/lint and native device results read and failures
   fixed; tests may not be removed or weakened to produce green.
2. First launch, sites/search, page navigation, tabs/pins/folders and Undo, history,
   all reachable settings, Reader/translation, chats/AI, attachments, Private,
   tablet/rotation/Back/keyboard and restart must be covered by actual scenarios.
3. Real Mac pairing, browser records in both directions and reconnect. The Mac app
   build, Worker capability and exact Android artifact are recorded. A local peer
   does not prove real product Sync.
4. Release-signed ARM64 APK installed and tested as a release build. Native proofs
   identify its SHA-256, not the debug APK or a differently signed copy.
5. Owner update: use an owned ARM64 emulator because no physical phone is
   available. Check fresh install, browsing and update preserving profile there,
   inspect actual screenshots and movement. Record the actual AVD/API/ABI/serial.
   Physical-phone testing is not required by the owner and must not be claimed.
6. Persistent owner release key. make-release-key.sh explicitly belongs to the
   owner and is never run by an agent. No test/debug key is shipped to users.
7. Upload immutable APK, verify downloaded bytes and certificate, then activate
   the website manifest and verify the live redirect and installation information.

## Current outside dependencies

Production Worker 56ad70f1-f281-49d8-a9fa-831c65204521 was deployed on
2026-10-29 with the Android admission/socket/broadcast gates. Live /v1/health
returns {ok:true,v:1,androidSync:1}. All 112 Worker tests, typecheck and dry-run
passed before deployment. An actual disposable production account passed 11 HTTP
protocol assertions, including legacy registration, offline-peer blocking,
capability refresh, Android admission, downgrade refusal and token preservation;
the temporary account was deleted. This is not actual Mac product pairing.
Android/RELEASE.md still requires compatible consumers,
then capability-aware Mac/iOS builds on every existing account device, before
Android may join. The gate must not be weakened. Existing public version numbers
alone do not prove this capability. A Mac/iOS public release is separate from the
owner's Android APK release request; prepare and prove the needed companion
change before asking to publish another platform.

The local release key was not found. Do not create or export one on behalf of
the owner. Prepare all software and acceptance before that final owner step.

## Publication tooling prepared

beta1-release-gate.py checks the exact APK, nonempty passing native proof,
real production Mac Sync, exact-APK emulator/device acceptance, owner certificate,
non-debuggable release package/version and 16 KiB ZIP alignment.
beta1-publish.py repeats these checks before uploading to the existing site's
Blob store. Its default is a local plan; --upload writes an immutable full-SHA
object, downloads it and verifies every byte, then prepares the exact /android.apk
route payload. It never activates a route or rebuilds the website. Read the staged
route diff and promote only this change after verifying the upload. No Android
file or download route has been published.

The live appcast checked on 2026-10-29 serves Mac 0.41.2. Its matching v0.41.2
source has no DevicePlatform.swift and does not register Android capability or
send the Android socket header. This is a concrete companion-update dependency,
not a reason to remove Mac Sync or weaken admission. The source-matched test Mac
has the compatibility patch; public Mac compatibility has not been released here.

## Current test harness corrections

The incorrect AppFlowTest import is removed. The historical beforeMixedOrder
scenario was moved intact into MixedKeptTreeBaselineDeviceTest: it expects the
old folder-first order and must only run against the older APK. It remains
compiled. The current mixedOrderSurvivesFoldingAndFreshActivity test remains
required by the default device inventory. Selection and publication guards
passed locally; Android/native compilation and runtime are still pending.

## Emulator qualification wave

- d74551ac5b3a4810 / 5c202931d17b31aec2f65088abd6ce8e119f200e:
  compile, JVM suites, lint and complete DEX inventory passed. JVM results:
  1228 passed, one oracle-dependent test skipped. Native: 240 reported, 187 passed,
  53 failed. This is the baseline, not acceptance or publication.
- The failed before log is retained in Documents/Codex/2026-10-28/android-beta1/.
  Progress logs, per-case outcomes, real gesture timestamps and the hardware
  opener's cold-readiness receipt are kept separately from the source.
- Fixture updates retain assertions and cover actual current controls: More and
  Back accessibility labels, answer-held Ask Again, Hide Chat, the real standalone
  first-run route, the current 264-point tablet sidebar and 8-point pane divider.
  Wide paired scenarios use a 1280-point window so both documents fit with Sidebar.
- Shield has an actual readiness failure in the cold app. A candidate fix keeps
  child timeouts from terminating the configuration collector and observes genuine
  port replacements. New JVM lifetime regressions cover timeout, disposal and
  replacement; their Android execution is pending.
- Focused job 16510fcb3d0d4e76 prepares R8/test-signed APK and real launch captures,
  then reruns the affected native classes with host GPU without concurrent farm
  work. It does not create a release key, assert phone coverage, or publish.
- Independent Mac compatibility job 57efe1d0950c4a83 passed 54 tests in eight
  suites. Its executable and source identity were retained for the real product
  pairing check. This does not constitute pairing, a provider answer or a public
  Mac release.
- Focused 16510fcb3d0d4e76 produced an R8 APK and passing basic launch/site/tab/
  settings captures. It predates the native host correction; do not publish it.
- Focused de1ffce54ec34eff had 46 expected native methods, 44 reported, 24 passed
  and 20 failed. R8, unit lifetime and basic release launch passed. Shield native
  connection now works, but teardown exposed a real Gecko Port dispatcher double
  shutdown. The test process crashed in multiple classes. This is not acceptance.
- Current regression 3007e87feec44e9e / 2cec754be55d includes extension-initiated
  Shield closure, stale-port refusal, current UI selectors, root-frame gesture
  revocation, exact-pixel folded plate offset, batched pointer samples and native
  web-control failure captures. Its release smoke also checks real cookie,
  localStorage, first-run and saved-tab retention through same-version APK
  reinstall. Older-version schema migration is not claimed.
- Shipped Shield script shutdown guards: two of three tests fail on the preceding
  frozen source, all three pass here. Native teardown acceptance remains pending.

## Latest evidence, 2026-10-29

- 3007e87feec44e9e finished: 47 native methods reported, 36 passed, 11 failed.
  The former Gecko NullHandle teardown crashes were absent. The R8 test-signed
  APK passed first-run/sites/tabs/settings and real saved-tab/cookie/localStorage
  retention across same-version reinstall. Its SHA-256 starts 8e9a319c70e5;
  it predates the current scoped Amazon Shield rules and must not be published.
- 58273b4714f843a6 and 8c88512476094c7f both paired the real Mac with the real
  Android release APK through production Sync after comparing the displayed
  verification digits. In the second run the Mac space arrived on Android.
  The harness missed the visible part of its clipped space pill; selecting by
  the exact text bounds is prepared. Bidirectional records/reconnect are not yet
  accepted. The second run confirmed disposable Mac Sync cleanup.
- Historical cda2358febbf42cb / d114b43cbfb5a268db910e0f0f90761771078c5b
  finished with 240 native methods reported, 212 passed and 28 failed. Swift
  Shield oracle and all 1184 app JVM tests passed, with no app JVM failure,
  error or skip. This old failed wave is preserved and is not current work. The full independent Swift oracle exposed two missing
  scoped Amazon allow rules from Mac commits bfe1df5a/dea5844d; these were ported
  with schema 13 and restrictions to the same ten Amazon domains.
- Changes after this frozen snapshot require a focused rerun: actual fast-flick
  input timing, a label-only fake engine's explicit document/window menu lease,
  native select-row indentation, and fresh project-chat action lifetimes after
  focus/lifecycle returns. The chat change is product code; the original failing
  rotation/recreation/native Back scenario remains required.
- The complete cda2358febbf42cb result is now retained: **1233 JVM tests passed**
  (1184 app + 49 core, no failures/errors/skips); **240 native methods reported,
  212 passed, 28 failed**. Its 30 MB evidence archive retains final results, JVM
  XML, every class transcript and one full copy of app-owned fixture evidence.
  Full native failure inventory: Documents/Codex/2026-10-28/android-beta1/full-inventory-status.txt.
- Finishing wave d81ecc1c03754fe3 / 03544bc77a962c78fcfab40e0a4c020fc33eb49f
  reruns 96 methods, R8 and exact new-APK profile/Mac Sync. No stage is accepted
  until its actual result is read. The unchanged real Swift Shield oracle is
  retained from cda and checked again against the current Kotlin converter.
- Additional product candidates: the same closing Spaces card accepts its
  original vertical regrab while ordinary actions stay disabled; original
  pointer callbacks cannot borrow a replacement card; Android 14+ WebAuthn
  declares CREDENTIAL_MANAGER_QUERY_CANDIDATE_CREDENTIALS. Android documents it
  as a normal browser permission required by hasCredentialResults:
  https://developer.android.com/reference/android/credentials/PrepareGetCredentialResponse
- A real failed screenshot showed 140% zoom where a fixture expected 110%:
  another fixture had persisted public 127.0.0.1 settings. Affected fictional
  pages now explicitly initialize that host to 100% mobile layout before their
  engine starts, preserving other hosts and all within-scenario persistence
  checks. This setup is confined to a verified owned emulator and is not used
  in release first-run/profile acceptance. Native event helpers also supply
  actual touchscreen/finger metadata; PiP/Home tests return via the real OS task.

### Production push coalescing correction

`244e2fc217eb400c` retained the same owner APK and again passed Mac pairing,
both directions and reconnect, but observed no new FCM work. Its disposable
Mac Sync cleanup passed. The following test correction changes no app/backend
code: the preceding force-stop/reconnect can consume the server's 60-second
`PUSH_EVERY` window, so the production marker must wait outside that window.
`0951802980914b81` (snapshot `e17d1fde4758`) keeps Android backgrounded for at
least 65 seconds, verifies it stays there, refreshes the work/journal baseline,
and then creates the distinct marker. The original failed receipts remain.
The retry is pending; this does not establish that coalescing was the sole
cause or that production delivery passes. The earlier isolated real Google
FCM proof `54124e36d8a245d1` ran on renderer-2, confirmed by `farm where`;
adhd was not its proven host.

### Production sender diagnostics

The corrected 65.44-second quiet-background run `0951802980914b81` still
observed no new FCM work or marker. Mac pairing, both directions and reconnect
passed again; cleanup passed. Coalescing was not established as the sole cause.
Its seven scoped receipts are retained in the local handoff's `owner-0951/`.

Diagnostics-only Worker changes are committed as
`3aa642f9a3f4f6d73370593a949e2964da6e2ebc`. They emit fixed accepted/deferred/
configuration/failure labels, never credentials, tokens, payloads or arbitrary
provider exception text. `53ca5ec4b73c466d`, frozen snapshot
`cb7d638229d8a0371efda3243bcf3899c53a082e`, passed all 113 Worker tests in 11
files, typecheck and bundling. The first driver attempt `90b7ac2fc56541a5`
failed because npm was absent from PATH; the driver now reuses the established
verified Node runtime. The passing driver's original receipt names base HEAD
rather than its frozen snapshot; that original is retained and a separate
source-identity receipt binds dispatcher snapshot, actual source-map contents
and bundle hash. The driver's metadata code was corrected to use REF.

The tested bundle SHA-256 is
`947331246a926a2072fb42a38cba64466c0a72df517fb99c02146dd2136b30bc`.
Six unique exact Find/Replace operations in Yab MCP deployed the equivalent
code as active Worker version `a02568f7`; source-path comments remain normalized
and the stale source-map reference was removed. Edited source SHA-256 is
`79c399f67ffb702e75499e251b3d44a32881d0f70fd133623c436c19eb611255`,
106,808 characters, 2,497 lines. Health returned HTTP 200 with androidSync 1.
Secrets and Durable Object bindings were retained. Failed file import and a
large editor paste were discarded before deployment; neither changed the
active Worker.

The APK itself remains byte-identical to its original producer. The no-rebuild
retry now verifies APK input scopes against `a595d4d8ae22cdc162db92e91930ab67d40c9314`
and backend source separately against tested commit `3aa642f9a`, rather than
claiming the diagnostics changed no server source. Runtime retry
`ca4bc2953a7644c3` (snapshot prefix `de9aecdac38c`) is pending.

The separately prepared Mac 0.43.0 (`7944878505494a22`, snapshot
`0391422f1bb16f03f67c272e06d44c96b9701ad7`) also lacks Android registration
and DevicePlatform support. Merely publishing that already prepared build
will not satisfy public Mac compatibility; the owner must rebuild from main
including `8b529b5`. This task does not release Mac.

### Native Worker fetch correction

The a02568f7 production log recorded `FCM wake failed` at stage
`transport-or-key`. Isolated Cloudflare HTTP preview then proved that an
object's direct native fetch call throws Illegal invocation, whereas a wrapper
returns 200 from a public fixture. That temporary preview branch was discarded
and never deployed. No production credentials were used in the preview.
The relevant platform contract is documented at
https://developers.cloudflare.com/workers/observability/errors/.

Source correction `0ebd5fa01eb8edb0b07be95aa156aa6f643c12c3` preserves the
native fetch receiver in the default GoogleFcm transport. It also adds a real
workerd regression with a below-runtime Miniflare outbound fixture, without
mocking global fetch or contacting Google. `3f84a50930324522`, frozen snapshot
`3d9967b790ae89b4f7ee572094960810a10a33a7`, fails that exact regression on
the former implementation with Illegal invocation at GoogleFcm.authorize.
The initial obsolete fetchMock-API attempt `3cd19865f3ad412c` is retained as a
harness failure, not a product reproduction. The subsequent broad-suite
attempt `862946e0cc30437e` stopped at an existing web-push retention timeout
before reaching the regression. The driver now runs the native regression
first and grants the unchanged 200-message functional case 15 seconds.

A single exact constructor replacement deployed the correction as active
Worker `3fd759c9`. Edited JavaScript SHA-256 is
`aaaa314332992bb3857d49e36693327d5006976ab6b0d965e710253d77734e2b`,
106,838 characters, 2,497 lines; health returned 200 with androidSync 1. No
secret, binding, Mac release or APK bytes changed. This is a deployed code
correction, not yet complete end-to-end production delivery acceptance.

Queued standalone after run `f1162d4d8c104aaf` was replaced before execution
by `ac17460a60df46da` (snapshot prefix `fadb7ed5f252`), combining the native
Worker regression, all Worker cases, bundling and the exact owner-APK
emulator proof. APK scopes remain verified against the producing snapshot;
Worker source is separately verified against 0ebd5fa01. The Native/WorkManager
receipt is still pending. The permanent check is retained under
`evals/golden/android_fcm_transport.md`.

The combined run stopped before any tests: its producing job's temporary `out/`
was unavailable. Original failure receipts are retained; this is not an after
regression result. Independent backend after job `558b0f518c1b41ba`, frozen
snapshot `3aedf1e689c6ba845a80049a5e9585fe41a9f0ad`, is pending.
The unchanged owner APK and byte-pinned original ca4b receipts are preserved in
renderer-2's permanent `~/.local/share/yab-android/beta1-retained-owner` folder.
`beta1-retained-owner-push.py` verifies source, actual signature/package/layout
and production resources before repeating native profile/Mac/background proof.
Completed static proof is explicitly reused; the historical failed push and
original producer failure are never rewritten as passes. Nine negative input
guards passed locally. No new native or backend after pass is claimed here.

Backend after job `558b0f518c1b41ba` has now passed: native default-fetch 1/1,
functional Worker 113/113, typecheck and bundling. Its frozen source identity is
correct, and twelve bundled source-map contents match 0ebd5fa01. The expected
deployed JavaScript differs only in documented comments/map directive, not code.
The permanent APK copy and three original receipts all match their exact hashes.
Recovery tooling is committed as `ab2557c49`. Native after job
`5c9eda9142c9465b`, snapshot prefix `d88448347893`, is pending independently.
No production delivery or full public Beta 1 acceptance is claimed yet.

Native run `5c9eda9142c9465b` stopped before emulator startup at the publication
inspector: current aapt2 reports `minSdkVersion:'29'`, whereas the inspector
recognized only legacy `sdkVersion:'29'`. The exact owner APK's typed binary
manifest independently confirms minimum 29, target/compile 37, version 1 and
the correct package. Its real badging is retained as a regression fixture.
Both label forms now require exactly one minimum value equal to 29; wrong,
missing or contradictory values remain rejected. All ten gate guard tests pass.
The native runner retains raw public badging before validation for diagnostics.
No APK, key, application source or publication acceptance requirement changed.
The next smoke also resolves the installed launcher's MAIN/LAUNCHER intent and
uses that normal first-launch route, recording its actual alias rather than
forcing MainActivity for the first launch. Later profile/reconnect restarts
retain their scoped explicit-activity behavior.

Run `37dbed2e778644b2` passed actual signature/package/SDK/ZIP and production
resource inspection, booted and installed the exact APK. Its first-launch test
used a package-only implicit MAIN/LAUNCHER intent, which Android refused even
though PackageManager resolved the enabled alias. The driver now starts that
resolved alias explicitly with MAIN/LAUNCHER, as a normal launcher does, rather
than forcing MainActivity. It captures both output streams on failure and stops
later cases after a failed first launch. This is a corrected test invocation,
not an application or APK change; a fresh native result is still required.

Actual production background receipt from `37dbed2e778644b2` PASSED: Google to
the owner release service to a fresh successful fcm-sync WorkManager entry;
journal 43 to 47; distinct tab marker version 2, clean and present before any
foreground, after 65.39 seconds of quiet. No direct push invocation or token
injection was used. Native approval/withdraw production paths were not rechecked.
The original run is still overall FAILED because of the earlier launcher test
command. Its other actual profile, both Mac directions and reconnect stages
passed; their scopes are retained separately. All receipts are copied locally.
The startup-only followup uses the corrected resolved alias, then normal
onboarding/browsing/profile checks. It explicitly does not claim a new FCM or
Mac proof. Full 16-scenario/public-Mac publication requirements remain intact.

Normal owner startup/profile followup `be85b97e5e4c40e7`, snapshot
`dc52491ff035027471a0b907ac49d78e4818caff`, PASSED. Android resolved Flat's
actual launcher alias; cold MAIN/LAUNCHER launch, normal No Mac onboarding,
browsing/settings and same-version tab/cookie/localStorage retention passed.
Its explicit scope excludes Mac/FCM reproof. The original 37db overall failure
and its independently passed production background receipt remain unchanged.

Additional public settings acceptance is prepared separately via
`--startup-only --ui-paths`: nine actual child pages, Back navigation and a
Dark/System round trip through the owner APK's accessibility UI. It uses no
instrumentation or app-data injection and does not claim complete publication
acceptance. The fresh run also records the owned app's ANR event buffer;
unchecked or nonempty ANR results hold the smoke. These additional cases are
not yet run. The APK and application source remain unchanged.

Public settings run `306a497dfa2c42e4`, snapshot
`cb3451763f111faa6b9590661f5452f34497b85f`, PASSED all ten real UI cases,
with the actual ANR event buffer checked, no owned-app ANR and no crash observed.
Nine child destinations and Dark/System persistence are now owner-APK proof.

The next separate `--startup-only --browser-paths` scope exercises real local
History, native query entry/routing after a process restart, software keyboard
and Back, and actual landscape/portrait accessibility rotation. It uses the
installed APK's public UI, not injected app data or a fake search response.
Google result content is outside its query-routing claim; a real search URL or
its persisted Google-query display projection is required. These new cases
are prepared, not yet passed; all remaining publication gates stay enforced.


### Rebuilt owner candidate required

The original owner APK 766e59cdf570 remains evidence, not a publishable final
candidate: actual browser run 2a4c1a7320f8487b passed History reopening and
software keyboard/Back, then lost a character from the native typed nonce.
Its search and rotation were not accepted. The delayed field model echo now
checks live text and the original input node; four JVM regressions are added
but not yet run. The ordinary real-query oracle remains strict.

Translation's missing public entry was reproduced in real MainActivity runs
6a04d3fa4b334695 and a58a0ed6b9ec45b4. Ninety latter observations had a live,
selected, connected page, but FAILED with The selected language is not
supported on this device. Source 02a291a0a normalizes regional locale tags;
dd6ee1337 also uses canonical BCP47 codes for legacy locale aliases. The two
new language JVM tests and unchanged real host assertion still need after
acceptance. The active after job is 1f00641ef857458e, snapshot 4c3ee988c48a.

Retaining was approved for the already implemented Extensions screen if it
works. Its previously null callback is restored by a565d8ea8, with existing
foreground/private guards and existing Settings search. Real owner install,
content script, Private exclusion and uninstall still require the new APK.
See evals/golden/android_field_echo.md for the explicit mobile Actions-catalog
exclusion; no Mac menu or command field is changed.

Actual owner-APK run 27303d8179164755 produced the first real Codex assistant
reply through production Mac Sync, confirmed in its native frame. Overall it
FAILED on a QA metadata error: chat sessions were looked up as remote tasks.
8ab1c9d9e uses the actual agents catalog and exact original prompt/session;
ee926699a also stops only this disposable world's Codex sessions at teardown.
Owner-APK second-turn reconnect and native approval decline remain unverified.

The new beta1-owner-candidate.py binds each followup to the unchanged actual
producer receipt/APK hashes, all six passing producer stages, owner certificate
and exact reviewed compiled source. Its five local file guards passed; this is
not native acceptance. beta1-production-release.py now requires an explicit
--source-snapshot instead of silently using the obsolete pre-fix source.
The next build must preserve the existing owner key and production Firebase
client, run the full JVM/lint/static batch, and collect new owner UI/backend
receipts. No new APK, upload, public Android route or Mac release yet.
