#!/bin/bash
# Baseline reservation regression, then every mapped suite on the candidate.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${YAB_FARM_OUT:?Run through the farm}"
BASE_COMMIT=c31305f5
BASE_TREE="$YAB_FARM_OUT/baseline-tree"
BASE_PROOF="$YAB_FARM_OUT/baseline"
mkdir -p "$BASE_TREE" "$BASE_PROOF"
git archive "$BASE_COMMIT" Package.swift Sources Tests Resources scripts evals YabCore/Client | tar -x -C "$BASE_TREE"
cp Tests/FastTests/AgentPageRoutingTests.swift "$BASE_TREE/Tests/FastTests/AgentPageRoutingTests.swift"
BASE_RESULT=0
YAB_PROBE="agent-download-before-${SLOT:-$$}" YAB_HISTORY=own YAB_FARM_OUT="$BASE_PROOF" CHROMIUM_SCRIPTS_TEST_FILTER=AgentPageRoutingTests \
    bash "$BASE_TREE/evals/chromium-scripts/tests.sh" 2>&1 | tee "$YAB_FARM_OUT/baseline.log" || BASE_RESULT=$?
BASE_RESULT="$BASE_RESULT" python3 - <<'PY'
import json, os
from pathlib import Path
out = Path(os.environ['YAB_FARM_OUT'])
events = [json.loads(line) for line in (out / 'baseline/focused.events.jsonl').read_text().splitlines()]
issues = [event['payload'] for event in events if event.get('kind') == 'event' and event['payload'].get('kind') == 'issueRecorded']
assert int(os.environ['BASE_RESULT']) != 0 and issues, 'Baseline must fail the new assertions'
assert all('rejectedChromiumURLDownloadPreservesReservation' in issue.get('testID', '') for issue in issues), issues
(out / 'baseline-summary.json').write_text(json.dumps({'commit': 'c31305f5', 'expectedFailure': True, 'issues': issues}, indent=2))
PY
bash evals/chromium-agents/batch.sh Sources/Fast/AgentBenchPage.swift Sources/Fast/ChromiumPage+AgentDownloads.swift Tests/FastTests/AgentPageRoutingTests.swift
