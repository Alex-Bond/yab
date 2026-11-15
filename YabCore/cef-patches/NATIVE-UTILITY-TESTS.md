# Exact native utility execution, no rebuild

This is an additive pipeline candidate after source79. It does not modify a
running build, any native C++ source/cache, farm job, flag, capability or SDK plan.

Verified production target //cef:libcef_static_unittests links
base/test/run_all_unittests.cc -> base::LaunchUnitTests -> original TestSuite/GTest.
It is a raw arm64 executable, not an application bundle. --single-process-tests
executes that original test suite directly without the launcher batch subprocesses
or launcher JSON. GTest XML is the authoritative completed-test evidence; the
runner derives a separate JSON receipt. No NSApplication/window initialization
is in that main. No CEF initialize, browser, UI fixture or full SDK acceptance.

The pinned source79 manifest contains exactly35 tests from the actual5 registered
sources:6 PDF credit,7 PDF delivery,5 PDF admission deadline,14 task IO and3 owned
resource-body relay cases. It also binds18 actual production/main/source files.
This utility graph does NOT exercise the full ProxyURLLoaderFactory, original
PDF facade/renderer, native permissions/group/browser or prepared app lifecycle.

After mandatory Ninja libcef_static_unittests finishes in the same source/compiler
lock, the runner checks thin arm64 Mach-O type and18 source hashes, discovers the
five suites and requires the exact expected set with no missing/extra/duplicate.
It executes the exact35 explicit names once in one process, no retry/shard/shuffle.
Success requires exit0, XML35 distinct run/completed cases and no disabled/skipped/
failed/error/global-failure cases. Empty discovery or apparently successful zero
execution is refused. Timeouts kill/reap only that child's new process group.
Child file size is bounded64MiB; discovery30s and execution300s are hard bounds.
No compiler or Ninja is invoked by the runner itself.

Artifacts in the fresh jobout/native-utility-tests directory:
- discovery.log and tests.log, including stderr;
- results.xml from actual GTest and strict derived results.json, retained on errors;
- exact binary/ICU hashes before and after and18 source hashes before/after;
- retained/libcef_static_unittests with original adjacent icudtl.dat;
- retained original source-inputs, runner and expectation manifest for replay.

The SDK gets scoped nativeUtilityTests provenance only when the candidate's real
run passed. Existing stockPatchComposition and stockNativePatchComposition are
unchanged. Framework link/distribution and actual SDK/app acceptance remain
mandatory. Pure harness test-native-unit-runner.py has no native execution.

Retained replay can run in an existing authorized farm job without rebuilding:
python3 RETAINED/native-unit-tests.py --source RETAINED/source-inputs \
 --binary RETAINED/libcef_static_unittests --expected-binary-sha256 EXACT_SHA

YAB_FARM_OUT is required and output must be a fresh child of that farm slot.
Without an explicit retained SHA the only accepted mode is the default exact
produced binary under the current original source lock, immediately after Ninja.
Do not run locally, launch a new compiler or substitute a current/old SDK binary.
Actual native tests remain NOT_RUN until a real produced binary passes this route.
