#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ${YAB_FARM_WORKER:-} == 1 ]] || { echo 'Run through ./farm exec.' >&2; exit 2; }
mkdir -p "$YAB_FARM_OUT/safe-browsing"
if [[ ${1:-} != shots ]]; then
  export YAB_PROBE="safe-browsing-unit-${SLOT:-$$}"
  export YAB_HISTORY=own
  swift test --scratch-path .build/dev-optimized -c debug -Xswiftc -O \
    --jobs "${YAB_JOBS:-4}" --filter SafeBrowsingTests \
    2>&1 | tee "$YAB_FARM_OUT/safe-browsing/tests.log"
  unset YAB_PROBE
fi
./build.sh 2>&1 | tee "$YAB_FARM_OUT/safe-browsing/build.log"
python3 -u evals/safe-browsing/check.py 2>&1 | tee "$YAB_FARM_OUT/safe-browsing/probe.log"
