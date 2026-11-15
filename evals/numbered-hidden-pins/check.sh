#!/bin/bash
# One logic regression: actual base selection versus the narrow patch.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'run through farm' >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || exit 2
base=${1:?base commit}
out=${YAB_FARM_OUT:?}
projection="$out/numbered-source"
mkdir -p "$projection"
git archive --output="$out/numbered-base.tar" "$base" Package.swift Sources Resources Tests
tar -xf "$out/numbered-base.tar" -C "$projection"
cp Tests/FastTests/NestedFoldersTests.swift "$projection/Tests/FastTests/NestedFoldersTests.swift"
testname=numberedKeysSkipHiddenKeptRowsInVisibleOrder
set +e
(cd "$projection" && YAB_PROBE=numbered-before YAB_HISTORY=own swift test --jobs 2 --filter "$testname") 2>&1 | tee "$out/before.log"
before=${PIPESTATUS[0]}
set -e
python3 - "$out/before.log" "$before" <<'PY'
import pathlib,sys
log=pathlib.Path(sys.argv[1]).read_text(errors='replace')
assert int(sys.argv[2])!=0 and 'Test numberedKeysSkipHiddenKeptRowsInVisibleOrder() failed' in log and 'Expectation failed' in log, 'base must execute and fail the behavioral regression; compile errors/skips are not proof'
PY
cp Sources/Fast/Browser.swift "$projection/Sources/Fast/Browser.swift"
(cd "$projection" && YAB_PROBE=numbered-after YAB_HISTORY=own swift test --jobs 2 --filter 'NestedFoldersTests|FoldersTests|KeyboardLayoutTests|ShortcutCatalogTests') 2>&1 | tee "$out/after.log"
python3 - "$out" "$base" <<'PY'
import json,pathlib,shutil,sys
out=pathlib.Path(sys.argv[1]); log=(out/'after.log').read_text(errors='replace')
assert 'Test numberedKeysSkipHiddenKeptRowsInVisibleOrder() passed' in log, 'regression was skipped or failed'
(out/'result.json').write_text(json.dumps({'base':sys.argv[2],'base_behavior_failed':True,'candidate_passed':True,'scope':'same base sources, changed Browser.swift and regression; actual numbered selection, no test replacement resolver'},indent=2)+'\n')
shutil.rmtree(out/'numbered-source'/'.build')
PY
