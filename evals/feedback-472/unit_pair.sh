#!/bin/bash
# One named farm job: committed main product source and the candidate,
# with exactly the same regression tests. No app, account or memory load.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'use the farm queue' >&2; exit 2; }
base="${1:?committed main base}"
out="${YAB_FARM_OUT:?}/figma-memory-stop"
mkdir -p "$out/candidate-source"
paths=(Sources/Fast/AgentBench.swift Sources/Fast/AgentBenchPage.swift Sources/Fast/Dialogs.swift Sources/Fast/Stuck.swift Sources/Fast/Tab.swift)
git rev-parse "$base" > "$out/main-commit"
git rev-parse "${REF:-HEAD}" > "$out/candidate-snapshot"
for path in "${paths[@]}"; do
  mkdir -p "$out/candidate-source/$(dirname "$path")"
  cp "$path" "$out/candidate-source/$path"
done
restore() {
  for path in "${paths[@]}"; do cp "$out/candidate-source/$path" "$path"; done
}
trap restore EXIT
for path in "${paths[@]}"; do git show "$base:$path" > "$path"; done
# Every product source/resource is main itself, not a guessed reverse patch.
git diff --quiet "$base" -- Sources Resources Package.swift build.sh yab.entitlements
echo "main source verified: $(cat "$out/main-commit")"
run_tests() {
  local phase="$1"
  set +e
  YAB_MEMORY_STOP_PHASE="$phase" swift test --filter AgentMemoryStopTests 2>&1 | tee "$out/$phase.log"
  local result="${PIPESTATUS[0]}"
  set -e
  printf '%s\n' "$result" > "$out/$phase.rc"
}
run_tests before
restore
run_tests after
python3 - "$out" <<'PY'
import json, pathlib, re, sys
out = pathlib.Path(sys.argv[1])
before, after = [(out/f'{phase}.log').read_text(errors='replace') for phase in ('before', 'after')]
codes = {phase: int((out/f'{phase}.rc').read_text()) for phase in ('before', 'after')}
compiled_error = re.compile(r'\.swift:\d+:\d+: error:|error: emit-module|error: fatalError')
main_failed = codes['before'] != 0 and 'Test run with' in before and not compiled_error.search(before)
candidate_passed = codes['after'] == 0 and 'Test run with' in after
report = {'main_commit': (out/'main-commit').read_text().strip(),
          'candidate_snapshot': (out/'candidate-snapshot').read_text().strip(),
          'before_rc': codes['before'], 'after_rc': codes['after'],
          'main_failed_at_runtime': main_failed, 'candidate_passed': candidate_passed,
          'status': 'pass' if main_failed and candidate_passed else 'blocked',
          'scope': 'MCP stopped-page lifecycle only; not an 8 GB Figma memory/OOM reproduction'}
(out/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report))
sys.exit(0 if report['status'] == 'pass' else 2)
PY
