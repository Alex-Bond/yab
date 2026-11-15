# Stress

Many agents at once in one Yab, each with tabs of its own: do they keep to
their own, and does Yab keep up.

    ./stress.py --bin PATH [--steps 5,10,20,40] [--pages 3] [--model haiku]

Each step starts N agents together in the world Yab (stress), each told to
open its own K pages on stress.localtest.me, read the code word on each and
save "worker:code" there. The pages write down every save, so a step is
graded by what was done: workers that saved all their pages with their own
code, saves on someone else's page or with someone else's code (crossings),
tabs two sessions claim, the bench's round trip every second (Yab's main
thread keeping up), and what Yab, the pages' processes and the agents' CLIs
added in memory.

A step stops, and the next isn't started, under 20% free memory or past a
3 s round trip: it runs on a Mac people use. A hundred agents need a Mac of
their own (adhd): each CLI is about 150 MB and each tab 50 to 150.

## Omnibox opening

Start a freshly built yab in its own visible test world, then run the stand:

    defaults write dev.serafim.fast.test.omnibox-perf bench -bool YES
    defaults write dev.serafim.fast.test.omnibox-perf welcomed -bool YES
    YAB_PROBE=omnibox-perf YAB_MEASURE=1 "/path/to/yab Dev.app/Contents/MacOS/yab" &
    python3 evals/stress/omnibox.py --world omnibox-perf --json /tmp/omnibox-frames.json

It measures the first and repeated opening over a local page, with 80 tabs,
10,000 history pages, 1,000 clipboard entries, and the actions panel. To make
history the first case after launch, use `--case history`. A different world
name keeps this fixture separate from other test runs. The script replaces
only its own generated history and clipboard entries when rerun.

For a genuinely cold open, stop that test app and run
`python3 evals/stress/omnibox.py --world omnibox-perf --seed-cold`, then relaunch
and add `--require-cold --case baseline` (or history, suggestions, tabs,
clipboard). The local data page normally is not persisted in a session;
seeding puts it there before startup, so a blank tab does not warm the field.
Seeding refuses a running world or a session containing other saved tabs.
The report counts both native field creations and visible presentations. The
shell is prepared with the window; a cold case must still be the process's
first visible opening. Startup showing a blank-tab field invalidates that claim.
Seed and relaunch for each cold case. The script dismisses Welcome, brings the
test window forward, and rejects measurements that end without focus or visibility.

`./bench --world omnibox-perf box appearance` reports the Liquid Glass and
traffic-light answers for every browser window. After opening a second window
and moving focus to another app, glass should remain true for both windows;
buttons should follow their real active state.

The History and Suggestions cases also type `page 999`, delete three digits
and type `123` at 16 ms per key. They check that `page 123` returns matching rows and
records frame gaps, main-thread stalls, key cost and injection delay. The card must
keep the same height throughout typing, with separate empty-query, matching-query
and no-match checks through the native editor. The last check sends keys immediately
after opening, before deferred focus, and exercises immediate Escape three times. Use
`--typing-interval-ms` and `--typing-seconds` to change the pace and result wait.
The Suggestions case seeds only in-memory history; the History case also fills
the local SQLite search index.

The report includes time to the first display-link callback and actual callback
gaps, independent main-queue latency probes every 5 ms, the longest main-run-loop
pass (including the first layout), main-thread CPU,
and synchronous opening time. Each case has one first and three repeated openings
by default; use `--warm-runs` to change that. An idle control after each fixture
shows the background stall level. The default failure limits are
two refresh periods (at least 25 ms) for a gap and 25 ms for opening; both can be changed with
`--max-gap-ms` and `--max-toggle-ms`. The gate uses actual callback arrival time
and main-queue latency, not the display link's scheduled timestamps. Run-loop
passes remain diagnostics: AppKit can deliver multiple callbacks within one
pass, so its total busy duration is not necessarily a freeze. These probes do
not directly measure frames rendered by the window server.
