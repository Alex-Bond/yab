#!/bin/bash
# One urgent display job: focused unit coverage and two actual app builds.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?base main commit}
mkdir -p "$YAB_FARM_OUT/pin-double-click"
swift test --filter 'PinnedHomeTests|TabRenameTests|PinPairTests' 2>&1 | tee "$YAB_FARM_OUT/pin-double-click/tests.log"
bash evals/perf-features/two_builds.sh "$base" -- \
    python3 -u evals/golden/pin_double_click.py --before-app '{base}' --app '{this}'
