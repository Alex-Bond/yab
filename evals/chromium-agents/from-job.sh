#!/bin/bash
# Transfer the exact prior output through the farm before a capture-only rerun.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?Run through the farm}"
SOURCE_JOB="${1:?Prior signed app job required}"
[[ "$SOURCE_JOB" =~ ^[0-9a-f]{16}$ ]]
shift
./farm fetch "$SOURCE_JOB" "$YAB_FARM_OUT/retained"
bash evals/chromium-agents/replay.sh "$YAB_FARM_OUT/retained/$YAB_TASK_NAME.app" "$@"
