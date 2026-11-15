#!/bin/bash
# Full native suite against actual main and candidate, in one frozen farm slot.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'use the farm queue' >&2; exit 2; }
base="${1:?actual main commit required}"
out="${YAB_FARM_OUT:?}/extension-error-pair"
mkdir -p "$out"
path=Sources/Fast/Extensions.swift
cp "$path" "$out/candidate.swift"
git rev-parse "$base^{commit}" > "$out/base-commit"
shasum -a 256 "$path" Tests/FastTests/ExtensionErrorReadTests.swift > "$out/input-sha256"
restore() { cp "$out/candidate.swift" "$path"; }
trap restore EXIT
git show "$base:$path" > "$path"
git diff --quiet "$base" -- Sources Resources Package.swift build.sh yab.entitlements
run_tests() {
    local phase="$1"
    set +e
    YAB_PROBE="extension-errors-$phase-${SLOT:-$$}" YAB_HISTORY=own \
      swift test --jobs 2 --filter ExtensionErrorReadTests 2>&1 | tee "$out/$phase.log"
    local codes=("${PIPESTATUS[@]}")
    set -e
    printf '%s\n' "${codes[0]}" > "$out/$phase.rc"
    [ "${codes[1]}" = 0 ]
}
run_tests before
restore
run_tests after
python3 - "$out" <<'PY'
import json,pathlib,re,sys
out=pathlib.Path(sys.argv[1])
names={'aFailedWorkerIsFoundWithoutReadingErrors','aWorkingWorkerIsLeftAlone','noWorkerIsNotWoken','loadDoesNotReadManifestOrContextErrors'}
report={'base':(out/'base-commit').read_text().strip(),'scope':'Full Fast module, live WebKit fixture workers and guarded manifest/context error access. Does not reproduce a dangling pointer or establish reporter-profile acceptance.'}
for phase in ['before','after']:
 log=(out/f'{phase}.log').read_text(errors='replace');rc=int((out/f'{phase}.rc').read_text())
 started=set(re.findall(r'◇ Test (\w+)\(\) started\.',log));passed=set(re.findall(r'✔ Test (\w+)\(\) passed ',log));failed=set(re.findall(r'✘ Test (\w+)\(\) failed ',log))
 complete=started==names and passed|failed==names and re.search(r'Test run with 4 tests(?: in 1 suite)? (?:failed|passed)',log) is not None
 expected={'loadDoesNotReadManifestOrContextErrors'}
 valid=complete and ((rc!=0 and failed==expected and 'manifest errors must stay unread too' in log and 'domain and code are unsafe as well as text' in log) if phase=='before' else (rc==0 and passed==names and not failed))
 report[phase]={'exit':rc,'passed':sorted(passed),'failed':sorted(failed),'valid':bool(valid)}
report['pass']=all(report[p]['valid'] for p in ['before','after'])
(out/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
sys.exit(0 if report['pass'] else 1)
PY
