#!/bin/bash
# YabCore's wire under load, end to end: the production src/transport.mm in a
# fake helper (transport_fake.mm), against this tree's client: every test of
# YabCore/Client, FlowControlTests and TransportOverflowTests among them. Then
# the same overflow test against BASE's client and transport, where it must
# end every page (transport_baseline.sh). Farm only, any Mac but main.
#   ./farm exec --name "..." -- bash YabCore/tests/transport_flow.sh [BASE]
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?}"
[ "${YAB_FARM_HOST:-}" != main ] || { echo 'Not on main' >&2; exit 2; }
BASE="${1:-97e3cb08af27397d4c5872397093e28bbc918c57}"
clang++ -std=c++20 -fobjc-arc -Wall -framework Foundation -framework CoreFoundation \
  YabCore/tests/transport_fake.mm -o "$YAB_FARM_OUT/transport-fake"
export YAB_TRANSPORT_FAKE="$YAB_FARM_OUT/transport-fake"
swift build --build-tests --package-path YabCore/Client --scratch-path "$YAB_FARM_OUT/client-build" 2>&1 | tee "$YAB_FARM_OUT/client-build.log"
# The suite takes about a minute. A hang (once 22 min at 0% CPU, with no
# fake alive) is sampled into the job's output and ended, not waited out.
# NSUnbufferedIO shows each test as it runs instead of at exit.
NSUnbufferedIO=YES swift test --skip-build --package-path YabCore/Client --scratch-path "$YAB_FARM_OUT/client-build" > "$YAB_FARM_OUT/client-tests.log" 2>&1 &
tests=$!
tail -f "$YAB_FARM_OUT/client-tests.log" & follow=$!
limit="${TRANSPORT_TEST_LIMIT:-600}" waited=0
while kill -0 "$tests" 2>/dev/null && [ "$waited" -lt "$limit" ]; do sleep 5; waited=$((waited + 5)); done
if kill -0 "$tests" 2>/dev/null; then
  echo "FAIL: client tests still running after ${limit}s; sampling" >&2
  for pid in $(pgrep -f YabCoreClientPackageTests.xctest || true); do sample "$pid" 5 -file "$YAB_FARM_OUT/hang-$pid.txt" >/dev/null 2>&1 || true; done
  ps -axo pid,ppid,etime,%cpu,stat,command | grep -E 'xctest|transport-fake' | grep -v grep >&2 || true
  pkill -f YabCoreClientPackageTests.xctest || true
fi
status=0; wait "$tests" || status=$?
kill "$follow" 2>/dev/null || true
[ "$status" -eq 0 ] || { echo "FAIL: client tests exit $status" >&2; exit 1; }
grep -q "Executed .* tests, with 0 failures" "$YAB_FARM_OUT/client-tests.log"
if grep -q "skipped" "$YAB_FARM_OUT/client-tests.log" && grep -q "Needs the transport fake" "$YAB_FARM_OUT/client-tests.log"; then
  echo 'FAIL: flow tests were skipped' >&2; exit 1
fi
echo 'PASS this tree: client and transport under load'
bash YabCore/tests/transport_baseline.sh "$BASE"
