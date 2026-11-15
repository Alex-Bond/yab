#!/bin/bash
# One farm-only parent/candidate pair; test-owned AS.start never forwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'use the farm queue' >&2; exit 2; }
base="${1:?actual parent commit required}"
[ "$base" = 48849b346239d302ec443893b9d4c4c376389433 ] || { echo 'wrong parent' >&2; exit 2; }
out="${YAB_FARM_OUT:?}/gmail-connect-gate-758"
mkdir -p "$out/candidate-source/Sources/Fast"
paths=(Sources/Fast/{AgentBenchMail,MailAgentLists,MailCenter,NativeControl}.swift)
test=Tests/FastTests/GmailConnectionGateTests.swift
printf '%s  %s\n' 7c7f9df0fbee2897b78fb5770efd7d0f357a902b67fd158fbb50390191c43de2 "$test" | shasum -a 256 -c -
git rev-parse --verify "$base^{commit}" > "$out/parent-commit"
git rev-parse --verify "$(cat "$YAB_FARM_OUT/../snapshot")^{commit}" > "$out/candidate-snapshot"
[ "$(git rev-parse --verify "${REF:?farm ref required}^{commit}")" = "$(cat "$out/candidate-snapshot")" ]
git rev-parse HEAD > "$out/source-head"
git diff --quiet "$(cat "$out/candidate-snapshot")" -- Sources Resources Package.swift build.sh yab.entitlements "$test"
[ "$(git diff --name-only "$base" -- Sources Resources Package.swift build.sh yab.entitlements)" = "$(printf '%s\n' "${paths[@]}")" ]
[ -z "$(git ls-files --others --exclude-standard -- Sources Resources)" ]
git diff --binary "$base" -- "${paths[@]}" > "$out/candidate.patch"
shasum -a 256 "$test" evals/feedback-758/gmail_connect_pair.sh evals/golden/gmail_connect_gate.sh > "$out/frozen-inputs.sha256"
for path in "${paths[@]}"; do cp "$path" "$out/candidate-source/$path"; done
restore() { local rc=0; for path in "${paths[@]}"; do cp "$out/candidate-source/$path" "$path" || rc=1; done; return "$rc"; }
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for path in "${paths[@]}"; do git show "$base:$path" > "$path"; done
git diff --quiet "$base" -- Sources Resources Package.swift build.sh yab.entitlements
run_tests() {
    local phase="$1"
    shasum -a 256 -c "$out/frozen-inputs.sha256"
    shasum -a 256 "${paths[@]}" > "$out/$phase-source.sha256"
    printf '%s\n' "feedback758-gmail-gate-$phase-${SLOT:-$$}" > "$out/$phase-probe"
    local command=(swift test --jobs 2 --filter GmailConnectionGateTests)
    [ "$phase" != after ] || command=(bash evals/golden/gmail_connect_gate.sh)
    set +e
    YAB_PROBE="$(cat "$out/$phase-probe")" YAB_HISTORY=own YAB_GOOGLE_CLIENT_ID=gmail-gate-fixture.apps.googleusercontent.com YAB_GOOGLE_CLIENT_SECRET= "${command[@]}" 2>&1 | tee "$out/$phase.log"
    local codes=("${PIPESTATUS[@]}")
    set -e
    printf '%s\n' "${codes[0]}" > "$out/$phase.rc"
    printf '%s\n' "${codes[1]}" > "$out/$phase.tee-rc"
    shasum -a 256 -c "$out/frozen-inputs.sha256"
    python3 - "$out" "$phase" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
out, phase = pathlib.Path(sys.argv[1]), sys.argv[2]
names = set('newGmailIsBlockedBeforeOAuthFactory hintOfExistingAccountDoesNotAuthorizeNewGmail differentExpectedAccountIsBlocked nonGmailAccountCannotAuthorizeGoogleOAuth exactExistingGmailAccountCanReauthenticate blockedNewRequestPreservesExistingReauthentication explicitCancelAndStaleAttemptDoNotAffectReplacement'.split())
regressions = names - {'exactExistingGmailAccountCanReauthenticate', 'explicitCancelAndStaleAttemptDoNotAffectReplacement'}
eligible_lines = {name: {66, 68, 75} for name in regressions}
eligible_lines['blockedNewRequestPreservesExistingReauthentication'] = {64, 67, 68, 140, 141}
required_issues = {(name, 75) for name in regressions if name != 'blockedNewRequestPreservesExistingReauthentication'} | {('blockedNewRequestPreservesExistingReauthentication', 140), ('blockedNewRequestPreservesExistingReauthentication', 141)}
log = (out / f'{phase}.log').read_text(errors='replace')
code = int((out / f'{phase}.rc').read_text())
started = re.findall(r'◇ Test (\w+)\(\) started\.', log)
passed_raw = re.findall(r'✔ Test (\w+)\(\) passed ', log)
failed_raw = re.findall(r'✘ Test (\w+)\(\) failed ', log)
passed, failed = set(passed_raw), set(failed_raw)
summary = re.findall(r'Test run with (\d+) tests in (\d+) suites? (passed|failed)', log)
asserted = set(re.findall(r'✘ Test (\w+)\(\) recorded an issue[^\n]*Expectation failed:', log))
issues = re.findall(r'✘ Test (\w+)\(\) recorded an issue at GmailConnectionGateTests.swift:(\d+):\d+: ([^\n]*)', log)
test_lines = pathlib.Path('Tests/FastTests/GmailConnectionGateTests.swift').read_text().splitlines()
issue_sources = [(name, int(line), test_lines[int(line) - 1].strip(), message) for name, line, message in issues]
manual_record = bool(re.search(r'^✘ Test blockedNewRequestPreservesExistingReauthentication\(\) recorded an issue at GmailConnectionGateTests.swift:67:\d+: Issue recorded\n↳ A blocked connection must fail, never succeed or remain pending$', log, re.M))
behavioral_only = len(issues) == log.count('recorded an issue') and all(line in eligible_lines.get(name, set()) and (('#expect(' in source and 'Expectation failed:' in message) or (name == 'blockedNewRequestPreservesExistingReauthentication' and line == 67 and source == '} else { Issue.record("A blocked connection must fail, never succeed or remain pending") }' and message == 'Issue recorded' and manual_record)) for name, line, source, message in issue_sources)
compiler_error = bool(re.search(r'\.swift:\d+(?::\d+)?: error:|error: (?:emit-module|fatalError|compile command|no tests found|Exited)|fatal error:|Build failed', log))
complete = len(started) == 7 and set(started) == names and len(passed_raw) == len(passed) and len(failed_raw) == len(failed) and len(summary) == 1 and summary[0][:2] == ('7', '1')
behavior = code != 0 and failed == regressions and asserted == regressions and passed == names - regressions and behavioral_only and required_issues <= {(name, line) for name, line, _, _ in issue_sources} if phase == 'before' else code == 0 and passed == names and not failed and not issues and not asserted and 'recorded an issue' not in log
valid = complete and behavior and not compiler_error and int((out / f'{phase}.tee-rc').read_text()) == 0 and summary[0][2] == ('failed' if phase == 'before' else 'passed')
def hashes(file):
    return {line.split(None, 1)[1].strip(): line.split()[0] for line in file.read_text().splitlines()}
report_path = out / 'summary.json'
report = json.loads(report_path.read_text()) if report_path.exists() else {}
parent = (out / 'parent-commit').read_text().strip()
paths = ['Sources/Fast/AgentBenchMail.swift', 'Sources/Fast/MailAgentLists.swift', 'Sources/Fast/MailCenter.swift', 'Sources/Fast/NativeControl.swift']
report.update(parent_commit=parent, candidate_snapshot=(out / 'candidate-snapshot').read_text().strip(), source_head=(out / 'source-head').read_text().strip(), frozen_inputs_sha256=hashes(out / 'frozen-inputs.sha256'), expected_tests=sorted(names), expected_parent_failures=sorted(regressions), required_parent_issues=sorted(required_issues))
report['parent_source_sha256'] = {p: hashlib.sha256(subprocess.check_output(['git', 'show', f'{parent}:{p}'])).hexdigest() for p in paths}
report['candidate_source_sha256'] = {p: hashlib.sha256((out / 'candidate-source' / p).read_bytes()).hexdigest() for p in paths}
report[phase] = dict(rc=code, test_count=len(started), summary=summary, passed=sorted(passed), failed=sorted(failed), expectation_failures=sorted(asserted), issue_sources=issue_sources, compiler_error=compiler_error, valid=valid, source_sha256=hashes(out / f'{phase}-source.sha256'), probe=(out / f'{phase}-probe').read_text().strip())
report['status'] = 'blocked' if not valid else ('pass' if phase == 'after' and report.get('before', {}).get('valid') else 'before-validated')
report['scope'] = 'Temporary new-Gmail OAuth admission gate; existing Gmail reauthentication, replacement and cancellation controls. Owned loopback bind and inert native session only; test AS.start never forwards; synthetic client, no real Google/network/presentation/user tab. No popup-cause or Google quota remediation claim.'
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
sys.exit(0 if valid else 2)
PY
}
run_tests before
restore
for path in "${paths[@]}"; do cmp "$path" "$out/candidate-source/$path"; done
git diff --quiet "$(cat "$out/candidate-snapshot")" -- Sources Resources Package.swift build.sh yab.entitlements
run_tests after
