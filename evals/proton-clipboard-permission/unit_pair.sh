#!/bin/bash
# Existing feedback-472 unit A/B pattern, one catalog hunk; no clipboard IO.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'use the farm queue' >&2; exit 2; }
base="${1:?committed main base}"
out="${YAB_FARM_OUT:?}/proton-clipboard-permission"
mkdir -p "$out"
path=Sources/Fast/Extensions.swift
cp "$path" "$out/candidate.swift"
git rev-parse "$base" > "$out/main-commit"
shasum -a 256 Tests/FastTests/ProtonClipboardPermissionTests.swift > "$out/test-sha256.txt"
restore() { cp "$out/candidate.swift" "$path"; }
trap restore EXIT
git show "$base:$path" > "$path"
git diff --quiet "$base" -- Sources Resources Package.swift build.sh yab.entitlements
run_tests() {
  local phase="$1"
  set +e
  YAB_PROBE="proton-886-${YAB_CHECK_WORLD:?}-$phase" swift test --filter ProtonClipboardPermissionTests 2>&1 | tee "$out/$phase.log"
  local result="${PIPESTATUS[0]}"
  set -e
  printf '%s\n' "$result" > "$out/$phase.rc"
}
run_tests before
restore
run_tests after
python3 - "$out" <<'PY'
import json,pathlib,re,sys
out=pathlib.Path(sys.argv[1])
logs={phase:(out/f'{phase}.log').read_text(errors='replace') for phase in ('before','after')}
codes={phase:int((out/f'{phase}.rc').read_text()) for phase in ('before','after')}
compile_error=re.compile(r'\.swift:\d+:\d+: error:|error: emit-module|error: fatalError')
name='Test declaredClipboardReadIsOfferedAndGrantedOnlyWhenChosen()'
before=codes['before']!=0 and name in logs['before'] and 'Expectation failed' in logs['before'] and not compile_error.search(logs['before'])
after=codes['after']==0 and name in logs['after'] and 'Test run with 1 test' in logs['after'] and not compile_error.search(logs['after'])
report={'main_commit':(out/'main-commit').read_text().strip(),'before_rc':codes['before'],'after_rc':codes['after'],
        'main_failed_at_runtime':before,'candidate_passed':after,'status':'pass' if before and after else 'blocked',
        'scope':'Optional-permission catalog and actual choice/store registration only; no clipboard or biometric operation'}
(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
sys.exit(0 if report['status']=='pass' else 2)
PY
