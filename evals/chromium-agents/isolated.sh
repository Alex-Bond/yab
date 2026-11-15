#!/bin/bash
# Diagnose failed original suites once on an exact sealed app, without building.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${WHERE:-}" in
    adhd|renderer-2|m4) ;;
    *) echo "Agent checks require a permitted remote farm worker" >&2; exit 1 ;;
esac
: "${YAB_FARM_OUT:?Run through the farm}"
RESULT=0
bash evals/chromium-agents/from-job.sh "$@" --only dialog || RESULT=1
APP="$YAB_FARM_OUT/$YAB_TASK_NAME.app"
trap 'python3 evals/chromium-scripts/ownership.py "$YAB_FARM_OUT"' EXIT
python3 -u evals/chromium-agents/lifecycle.py --app "$APP" --out "$YAB_FARM_OUT/cleanup-isolated" --suite cleanup || RESULT=1
python3 -u evals/chromium-agents/cleanup_focus.py --app "$APP" --out "$YAB_FARM_OUT/cleanup-focused" || RESULT=1
exit "$RESULT"
