# Perf baselines (level 1)

For feedback #1776, `Phone/scripts/launch-speed-check.sh BASE` compares the
exact starting main source with the candidate in one exclusive display farm
job. Submit with `--needs ios-sim,xcodegen --exclude-host main --exclude-host m4`.
It checks a 2,000-icon cache with a main-actor heartbeat, profile/model loading
with 2,000 saved tabs, and an iPhone 11 start page that accepts typed input.
The baseline must fail the specific main-actor availability assertion; a build
or simulator failure is not accepted as a reproduction. Candidate suites and
both UI probes must pass. Outputs are under the job's `launch-speed/` folder.

The UI probe reports process restarts and foreground resumes separately.
Its end-to-end samples include XCTest and typing overhead; the native
`XCTApplicationLaunchMetric` reports responsive process launch separately.
The first restart is not an OS cold-cache or reboot measurement. These are
Debug simulator measurements on the worker's CPU, not A13 timings. An isolated
profile skips personal sync and the shared production favicon cache. Both
trees get the same isolated-cache routing hook, and the UI fixture restores
2,000 persisted icons from its own profile directory on every process restart.
No network permission is added. The cache probe measures main-actor availability
separately from launch. Published 0.1.30 and reporter-profile
acceptance remain separate requirements (`Phone/qa/iphone-launch-cache.json`).

Observed on 2026-11-04, job `805b64c769844901` (adhd, Debug, iPhone 11):

| Measurement | Main | Candidate |
| --- | ---: | ---: |
| Main-actor queue delay during 2,000-icon restoration | 272.01 ms | 5.27 ms |
| Native responsive first frame, mean of five | 5.837 s | 3.101 s |
| First process, including XCTest, queries and typing | 15.891 s | 15.765 s |
| Cached process restart, median of four, including automation | 9.977 s | 8.173 s |
| Foreground resume, median of five, including automation | 2.139 s | 2.069 s |

These are shared-worker observations, not accepted overall launch benchmarks.
Start load averages were 34.43 / 46.70 / 69.28; the baseline native metric had
32.841% relative standard deviation. The cache availability assertion fails on
main and passes in the candidate. All 30 candidate tests and both UI probes
passed; final source tests also passed in `41e2195a5e9b485f`.
[Raw samples, stall events and screenshots](../../docs/evidence/iphone-launch-cache-2026-11-04/results.json)
retain the measurement limits. Feedback #1776 is not verified as fixed.
[Before](../../docs/evidence/iphone-launch-cache-2026-11-04/before.png) and
[after](../../docs/evidence/iphone-launch-cache-2026-11-04/after.png) show the
same fixture profile and usable field; both captures were inspected.

`Phone/scripts/remote perf` measures on adhd's simulator and compares with
`baselines/<mac>_<model>_<runtime>.json`, the last run someone made the
baseline with `remote perf --baseline` (the first run on a new Mac, model or
runtime becomes the baseline by itself). A simulator draws on the Mac's GPU,
so numbers mean something only against the same Mac, the same simulator and
the same runtime: never compare across files.

What is in a baseline (`Phone/scripts/lib/perf.py collect`):

- `frames`: per transition (PerfTests, TransitionCatalog) and per signpost,
  FrameMeter's numbers for every repeat and their medians: duration, frames,
  worst frame, long frames (over 1.5 frame times), hitch time per second,
  main thread time per frame (average and worst, each frame's layout and
  commit included, on the wall clock and as the thread's own CPU time), the
  first frame after the motion began and the main
  thread's work in it, and the Motion's own duration.
- `memory`: per memory test (`testPagingMemory`, `testScrollMemory`), the
  resident memory of Yab's process and of WebKit's (WebContent, Networking,
  GPU) at the end of each repeat, sampled once a second by the script from
  the Mac's side, since XCTMemoryMetric sees Yab's process only.
- `tests`: XCTest's metrics per test: the signposts' durations
  (XCTOSSignpostMetric), launch time, Yab's memory and CPU.
- the Mac's load when it ran: adhd is shared, and a run at load 300 is not a
  run at load 30. Make a baseline when adhd is quiet, and look at the load
  before believing a regression.

XCTest's first repeat of each measure is a warm-up it leaves out of its own
numbers; FrameMeter's lines and the memory samples of that repeat are left
out the same way.

A run fails (`perf.py compare`, exit 1) on any of these:

- a transition's number worse than the baseline by more than 10 % and by
  more than its noise floor: FrameMeter's main thread per frame, wall and
  CPU (0.5 ms),
  worst frame (4 ms), hitch time (5 ms/s), long frames (0.05), duration
  (20 ms), and the signpost's duration from XCTest (20 ms);
- a transition of the baseline this run didn't measure (a broken signpost,
  a test that no longer runs it);
- a motion off its Motion's duration by more than 20 % and at least 50 ms
  (PLAN-iphone.md 5.3; the end is said a frame or two after it arrives);
- the main thread over 8 ms in a transition's worst frame, the median of the
  repeats (PLAN-iphone.md 8.2, the simulator's column): its own CPU time
  (`main_cpu_max_ms`), since its wall time also holds the waits for a core
  that a loaded adhd adds (11.6 ms of wall time at load 556 in the first run);
- Yab's and WebKit's memory growing by more than 30 MB from the first
  measured repeat of a memory test to the last (8.2: no growth after paging).

Launch, Yab's memory and CPU against the baseline are judged by the same 10 %
and floors (launch 50 ms, memory 2 MB, the processes' samples 20 MB, CPU time
50 ms) and shown, but don't fail the run: on a shared Mac they move with its
load (a launch took twice as long at load 620 as at 740, nothing changed).
Make a new baseline when a change is meant to cost something, and say so in
its commit.
