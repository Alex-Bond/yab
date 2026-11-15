#!/bin/bash
# Both test frameworks, with one filter. This is not a release invocation.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${WHERE:-}" in
    adhd|renderer-2|m4) ;;
    *) echo "Agent tests require a permitted remote farm worker" >&2; exit 1 ;;
esac
CHROMIUM_TEST_ID="${YAB_FARM_JOB:-${YAB_CHECK_WORLD:-}}"
: "${CHROMIUM_TEST_ID:?Run through the farm}"
export YAB_PROBE="chromiumpage-tests-${CHROMIUM_TEST_ID#farm-}"
export YAB_HISTORY=own
RESULT=0
bash evals/chromium-scripts/tests.sh 2>&1 | tee "$YAB_FARM_OUT/native-tests.log" || RESULT=1
# The event file is only created after this snapshot's test bundle compiled.
# Do not run skip-build against a stale bundle after a compilation failure.
if [[ ! -s "$YAB_FARM_OUT/focused.events.jsonl" ]]; then exit 1; fi
swift test --skip-build --disable-swift-testing --filter "$CHROMIUM_SCRIPTS_TEST_FILTER" 2>&1 | tee "$YAB_FARM_OUT/xctest.log" || RESULT=1
python3 - <<'PY'
import json, os, re
from pathlib import Path
out = Path(os.environ['YAB_FARM_OUT'])
text = (out / 'xctest.log').read_text()
summary = re.search(r"Test Suite 'Selected tests' (passed|failed)", text)
methods = re.findall(r"Test Case '-\[FastTests\.(\w+) (test\w+)\]' (passed|failed|skipped)", text)
# These are the agent permission/eval XCTest suites that the Swift Testing
# entrypoint alone cannot execute. Require each selected method to finish.
required = {}
for suite in ('AgentHoldTests', 'AgentEvalTests'):
    source = Path('Tests/FastTests') / (suite + '.swift')
    required[suite] = re.findall(r'\bfunc\s+(test\w+)\s*\(', source.read_text())
missing = [(suite, method) for suite, names in required.items() for method in names
           if not any(row[:2] == (suite, method) for row in methods)]
complete = bool(summary) and bool(methods) and not missing
result = {'complete': complete, 'outcome': summary[1] if summary else None,
          'completedMethods': len(methods), 'requiredAgentMethods': required, 'missing': missing}
(out / 'xctest-summary.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result), flush=True)
if not complete: raise SystemExit('XCTest coverage incomplete')
PY
exit "$RESULT"
