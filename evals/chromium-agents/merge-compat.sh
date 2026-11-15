#!/bin/bash
# Small native follow-up. App Swift inputs are identical to merge-batch.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${WHERE:-}" in
    adhd|renderer-2|m4) ;;
    *) echo "Native reconciliation requires a permitted remote farm worker" >&2; exit 1 ;;
esac
mkdir -p "$YAB_FARM_OUT/core"
YAB_FARM_OUT="$YAB_FARM_OUT/core" bash YabCore/build.sh > "$YAB_FARM_OUT/core-app.txt"
swift test --package-path YabCore/Client 2>&1 | tee "$YAB_FARM_OUT/client-tests.log"
