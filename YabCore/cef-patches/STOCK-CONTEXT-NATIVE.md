# Native overlay stock-context composition

Bounded repair for the source77 configure failure445d. The CEF project hook runs
its stock patcher again after the native series. Three applied stock patches
lost reverse recognition only because the native overlay changed context:
- chrome_browser_browser: CreateTargetContents leading context;
- chrome_browser_extensions: extension_tab_util include trailing context;
- webkit_plugin_info_2015: devtools_session include trailing context.

The companion reconstructs exactly two hash-pinned versions per patch. Every
original upstream +/- payload line remains byte-exact. Two hunks lose only unused
context lines. The extension include hunk uses the exact native77 delegate-guard
lines as context because ordinary Git refuses zero trailing context there.
No --unidiff-zero, patcher flags/returns, ignored failures, native revert or gate
relaxation. Unknown patch hash or neither complete reverse-recognized source
state refuses before any patch metadata write.

Classify strict original reverse recognition first, otherwise strict effective
reverse recognition. This keeps stock62 on its original metadata and native77 on
the compatible context. For selected versions, strictly reverse/forward on a
private24-file copy and require exact byte equality. Live source only receives
reverse --check. --apply changes only the three stock patch metadata files,
requires YAB_FARM_OUT and YAB_OWNCEF_LOCKED=1, validates all three before writes,
and rechecks native hashes. Writes are atomic per file and idempotent.

configure.sh runs this before its first stock patcher (cached77 retry) and again
after native apply-series, before the internal CEF project stock patcher. The
existing blink stock-context.sh and stockPatchComposition schema are unchanged.
Separate stock-native-source-composition.json is emitted by the companion; the
SDK receives stockNativePatchComposition with original/effective/selected/
semantics hashes and strict reverse/roundtrip/native-byte preservation booleans.

Read-only command: bash YabCore/cef-patches/stock-context-native.sh --check.
Apply only through the existing root-owned headless source farm job/lock.
Never invoke apply directly on the live checkout from an agent shell.

Filesystem regression route (no compiler, source/cache mutations or new farm job):
python3 YabCore/cef-patches/test-stock-context-native.py --stock62 COPIED62 \
 --native77 COPIED77 --original-patches PINNED_ORIGINAL3 \
 --effective-patches PINNED_EFFECTIVE3 --work FRESH_PRIVATE_OUTPUT

Production script tests cover original62 recognition, effective77 recognition,
private apply, idempotence,62 metadata restoration, partial third source refusal,
unknown third hash refusal before earlier writes, missing farm output and missing
source lock, plus the actual SDK provenance block retaining legacy blink schema.
These are filesystem/pipeline proofs, not native compilation or SDK acceptance.
