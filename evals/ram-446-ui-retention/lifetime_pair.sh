#!/bin/bash
# One farm-only source pair, identical focused tests; no app or RAM measurement.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'use the farm queue' >&2; exit 2; }
base="${1:?actual parent commit required}"
[ "$base" = eedc6a76dd9e978094345b73b15e85da960c751d ] || { echo 'wrong parent' >&2; exit 2; }
out="${YAB_FARM_OUT:?}/rule-lifetime-446"
mkdir -p "$out/candidate-source"
paths=(Sources/Fast/Extensions.swift Sources/Fast/ExtensionRules.swift)
test=Tests/FastTests/ExtensionRuleLifetimeTests.swift
printf '%s  %s\n' 3d1adad9178e1dc14d1c6210f8e6188a5f93fca9b1aab77515d1d19193080def "$test" | shasum -a 256 -c -
git rev-parse --verify "$base^{commit}" > "$out/parent-commit"
git rev-parse --verify "$(cat "$YAB_FARM_OUT/../snapshot")^{commit}" > "$out/candidate-snapshot"
[ "$(git rev-parse --verify "${REF:?farm ref required}^{commit}")" = "$(cat "$out/candidate-snapshot")" ]
git rev-parse HEAD > "$out/source-head"
git diff --binary "$base" -- "${paths[@]}" > "$out/candidate.patch"
shasum -a 256 "$test" evals/ram-446-ui-retention/lifetime_pair.sh > "$out/frozen-inputs.sha256"
for path in "${paths[@]}"; do
    mkdir -p "$out/candidate-source/$(dirname "$path")"
    cp "$path" "$out/candidate-source/$path"
done
restore() { local rc=0; for path in "${paths[@]}"; do cp "$out/candidate-source/$path" "$path" || rc=1; done; return "$rc"; }
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for path in "${paths[@]}"; do git show "$base:$path" > "$path"; done
git diff --quiet "$base" -- Sources Resources Package.swift build.sh yab.entitlements
[ -z "$(git ls-files --others --exclude-standard -- Sources Resources)" ]
run_tests() {
    local phase="$1"
    shasum -a 256 -c "$out/frozen-inputs.sha256"
    shasum -a 256 "${paths[@]}" > "$out/$phase-source.sha256"
    printf '%s\n' "ram446-rule-lifetime-$phase-${SLOT:-$$}" > "$out/$phase-probe"
    set +e
    YAB_PROBE="$(cat "$out/$phase-probe")" YAB_HISTORY=own \
        swift test --jobs 2 --filter ExtensionRuleLifetimeTests 2>&1 | tee "$out/$phase.log"
    local codes=("${PIPESTATUS[@]}")
    set -e
    printf '%s\n' "${codes[0]}" > "$out/$phase.rc"
    printf '%s\n' "${codes[1]}" > "$out/$phase.tee-rc"
    shasum -a 256 -c "$out/frozen-inputs.sha256"
    python3 - "$out" "$phase" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
out, phase = pathlib.Path(sys.argv[1]), sys.argv[2]
names = {'failedProductionLoadReleasesPreparedRules', 'missingContextDisableAndRemoveReleasePreparedRules', 'successfulDisablePreservesSiblingRules', 'unrelatedControllerCannotReleaseLoadedRules'}
regressions = {'failedProductionLoadReleasesPreparedRules', 'missingContextDisableAndRemoveReleasePreparedRules'}
log = (out / f'{phase}.log').read_text(errors='replace')
code = int((out / f'{phase}.rc').read_text())
started = re.findall(r'◇ Test (\w+)\(\) started\.', log)
passed = set(re.findall(r'✔ Test (\w+)\(\) passed ', log))
failed = set(re.findall(r'✘ Test (\w+)\(\) failed ', log))
summary = re.findall(r'Test run with (\d+) tests in (\d+) suites? (passed|failed)', log)
asserted = set(re.findall(r'✘ Test (\w+)\(\) recorded an issue[^\n]*Expectation failed:', log))
issues = re.findall(r'✘ Test (\w+)\(\) recorded an issue at ExtensionRuleLifetimeTests.swift:(\d+):\d+: ([^\n]*)', log)
test_lines = pathlib.Path('Tests/FastTests/ExtensionRuleLifetimeTests.swift').read_text().splitlines()
issue_sources = [(name, test_lines[int(line) - 1].strip(), message) for name, line, message in issues]
cleanup_only = len(issues) == log.count('recorded an issue') and all('#expect(' in source and ('ExtensionRules.report(' in source or '!ExtensionRules.holds(' in source) and 'Expectation failed:' in message for _, source, message in issue_sources)
report_failures = {name for name, source, _ in issue_sources if 'ExtensionRules.report(' in source and '.isEmpty' in source}
compiler_error = bool(re.search(r'\.swift:\d+(?::\d+)?: error:|error: (?:emit-module|fatalError|compile command|no tests found|Exited)|fatal error:|Build failed', log))
complete = len(started) == len(names) and set(started) == names and len(summary) == 1 and int(summary[0][0]) == len(names) and int(summary[0][1]) == 1
behavior = code != 0 and failed == regressions and asserted == regressions and passed == names - regressions and cleanup_only and report_failures == regressions if phase == 'before' else code == 0 and passed == names and not failed and not issues and not asserted
valid = complete and behavior and not compiler_error and int((out / f'{phase}.tee-rc').read_text()) == 0 and summary[0][2] == ('failed' if phase == 'before' else 'passed')
def hashes(file):
    return {line.split(None, 1)[1].strip(): line.split()[0] for line in file.read_text().splitlines()}
report_path = out / 'summary.json'
report = json.loads(report_path.read_text()) if report_path.exists() else {}
parent = (out / 'parent-commit').read_text().strip()
source_paths = ['Sources/Fast/Extensions.swift', 'Sources/Fast/ExtensionRules.swift']
report.update(parent_commit=parent, candidate_snapshot=(out / 'candidate-snapshot').read_text().strip(), source_head=(out / 'source-head').read_text().strip(), frozen_inputs_sha256=hashes(out / 'frozen-inputs.sha256'), expected_tests=sorted(names), expected_parent_failures=sorted(regressions))
report['parent_source_sha256'] = {p: hashlib.sha256(subprocess.check_output(['git', 'show', f'{parent}:{p}'])).hexdigest() for p in source_paths}
report['candidate_source_sha256'] = {p: hashlib.sha256((out / 'candidate-source' / p).read_bytes()).hexdigest() for p in source_paths}
report[phase] = dict(rc=code, test_count=len(started), summary=summary, passed=sorted(passed), failed=sorted(failed), expectation_failures=sorted(asserted), issue_sources=issue_sources, compiler_error=compiler_error, valid=valid, source_sha256=hashes(out / f'{phase}-source.sha256'), probe=(out / f'{phase}-probe').read_text().strip())
report['status'] = 'blocked' if not valid else ('pass' if phase == 'after' and report.get('before', {}).get('valid') else 'before-validated')
report['scope'] = 'Prepared rule ownership after real load failure, nil-context disable/remove, successful disable, sibling and foreign-controller controls; YAB_HISTORY=own, no app, profile, display or RAM claim.'
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
sys.exit(0 if valid else 2)
PY
}
run_tests before
restore
for path in "${paths[@]}"; do cmp "$path" "$out/candidate-source/$path"; done
run_tests after
