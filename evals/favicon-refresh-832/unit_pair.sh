#!/bin/bash
# Compare the reviewed 832 author implementation with the cache/cookie revision.
# Reuses evals/feedback-472/unit_pair.sh's worker-only source swap pattern.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'use the farm queue' >&2; exit 2; }
base="${1:?reviewed author base}"
out="${YAB_FARM_OUT:?}/favicon-refresh-832-revision"
mkdir -p "$out/candidate-source"
paths=(Sources/Fast/Icons.swift)
git rev-parse "$base" > "$out/reviewed-author-commit"
for path in "${paths[@]}"; do
  mkdir -p "$out/candidate-source/$(dirname "$path")"
  cp "$path" "$out/candidate-source/$path"
done
shasum -a 256 Tests/FastTests/FaviconRefreshTests.swift Tests/FastTests/Support/LocalNetworkFixture.swift > "$out/test-sha256.txt"
restore() {
  for path in "${paths[@]}"; do cp "$out/candidate-source/$path" "$path"; done
}
trap restore EXIT
for path in "${paths[@]}"; do git show "$base:$path" > "$path"; done
# Baseline is the unlanded reviewed author commit, NOT a claim of main failure.
# New test/support files are the only baseline overlay.
git diff --quiet "$base" -- Sources Resources Package.swift build.sh yab.entitlements
run_tests() {
  local phase="$1"
  set +e
  YAB_PROBE="favicon-refresh-832-revision-${YAB_CHECK_WORLD:?}-$phase" swift test --filter '(^|\.)(FaviconRefreshTests|IconsTests)(/|\.|$)' 2>&1 | tee "$out/$phase.log"
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
logs = {phase: (out/f'{phase}.log').read_text(errors='replace') for phase in ('before', 'after')}
codes = {phase: int((out/f'{phase}.rc').read_text()) for phase in ('before', 'after')}
compile_error = re.compile(r'\.swift:\d+:\d+: error:|error: emit-module|error: fatalError')
named = 'Test manualRefreshBypassesCachedMarkupAndIconBytes()'
cookie = 'Test publicIconRequestsDoNotCarryCookiesBetweenCandidates()'
before_failed = (codes['before'] != 0 and named in logs['before'] and cookie in logs['before']
                 and re.search(re.escape(named) + r' failed', logs['before'])
                 and re.search(re.escape(cookie) + r' failed', logs['before'])
                 and 'Expectation failed' in logs['before'] and 'Test run with 23 tests' in logs['before']
                 and not compile_error.search(logs['before']))
after_passed = (codes['after'] == 0 and named in logs['after'] and cookie in logs['after']
                and 'Test run with 23 tests' in logs['after'] and not compile_error.search(logs['after']))
report = {'reviewed_author_commit': (out/'reviewed-author-commit').read_text().strip(), 'before_rc': codes['before'],
          'after_rc': codes['after'], 'reviewed_author_failed_at_runtime': before_failed,
          'candidate_passed': after_passed, 'status': 'pass' if before_failed and after_passed else 'blocked',
          'scope': 'Actual cacheable HTTP root/icon freshness, normal automatic cache reuse, and synthetic cookie isolation; sequential refresh only, no menu/profile E2E'}
(out/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report))
sys.exit(0 if report['status'] == 'pass' else 2)
PY
