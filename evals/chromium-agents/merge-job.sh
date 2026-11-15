#!/bin/bash
# One signed build, then app acceptance and direct native-continuation proof.
set -euo pipefail
cd "$(dirname "$0")/../.."
RESULT=0
bash evals/chromium-agents/job.sh "$@" || RESULT=1
if [[ -s "$YAB_FARM_OUT/yab-app-path.txt" ]]; then
    APP="$(cat "$YAB_FARM_OUT/yab-app-path.txt")"
    python3 -u evals/chromium-agents/dialogs.py --app "$APP" --out "$YAB_FARM_OUT/native-dialogs" || RESULT=1
fi
exit "$RESULT"
