#!/bin/bash
# Logic before/after on the committed track baseline, then mapped regressions.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${WHERE:-}" in
    adhd|renderer-2|m4) ;;
    *) echo "Agent tests require a permitted remote farm worker" >&2; exit 1 ;;
esac
: "${YAB_FARM_OUT:?Run through the farm}"
BASE_COMMIT=5f52ddc9dd0b056ab6ab27ae50c39b654f2ea169
BASE_TREE="$YAB_FARM_OUT/download-baseline"
BASE_PROOF="$YAB_FARM_OUT/download-before"
mkdir -p "$BASE_TREE" "$BASE_PROOF"
# Archive reads git metadata only. Do not alter a branch, index or worktree.
git archive "$BASE_COMMIT" | tar -x -C "$BASE_TREE"
cp Tests/FastTests/AgentPageRoutingTests.swift "$BASE_TREE/Tests/FastTests/AgentPageRoutingTests.swift"
BEFORE_RESULT=0
YAB_FARM_OUT="$BASE_PROOF" CHROMIUM_SCRIPTS_TEST_FILTER=AgentPageRoutingTests \
    bash "$BASE_TREE/evals/chromium-scripts/tests.sh" 2>&1 | tee "$YAB_FARM_OUT/download-before.log" || BEFORE_RESULT=$?
BEFORE_RESULT="$BEFORE_RESULT" python3 - <<'PY'
import json, os
from pathlib import Path
out = Path(os.environ['YAB_FARM_OUT'])
events = [json.loads(line) for line in (out / 'download-before/focused.events.jsonl').read_text().splitlines()]
issues = [event['payload'] for event in events
          if event.get('kind') == 'event' and event['payload'].get('kind') == 'issueRecorded']
owned = 'rejectedChromiumURLDownloadPreservesReservation'
assert int(os.environ['BEFORE_RESULT']) != 0, 'Baseline unexpectedly passed'
assert len(issues) == 4 and all(owned in issue.get('testID', '') for issue in issues), issues
result = {'commit': '5f52ddc9dd0b056ab6ab27ae50c39b654f2ea169',
          'expectedFailure': True, 'issues': len(issues), 'test': owned}
(out / 'download-before.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
PY
bash evals/chromium-agents/batch.sh Sources/Fast/AgentBenchPage.swift Tests/FastTests/AgentPageRoutingTests.swift
