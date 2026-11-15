#!/bin/bash
# One farm-only parent/candidate unit pair; no provider launch, app or network.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${YAB_FARM_WORKER:-}" = 1 ] || { echo 'use the farm queue' >&2; exit 2; }
base="${1:?actual parent commit required}"
[ "$base" = 10630f325c4cb4b2e727e45baf6a531af368db68 ] || { echo 'wrong parent' >&2; exit 2; }
out="${YAB_FARM_OUT:?}/remote-task-permit-754"
mkdir -p "$out/candidate-source/Sources/Fast"
path=Sources/Fast/Agents.swift
test=Tests/FastTests/RemoteTaskProviderPermitTests.swift
controls=(Tests/FastTests/{RemoteTaskFoundationTests,TaskLaunchTests,TaskObservationTests,RemoteTaskReadTests}.swift)
filter='RemoteTaskProviderPermitTests|RemoteTaskFoundationTests|TaskLaunchTests|TaskObservationTests|RemoteTaskReadTests/requestAndResponsePoliciesRejectPostFilesCredentialsPopupsAndDownloads'
printf '%s  %s\n' a6d62cec9e17185de1ce02557b5fd15403d764f63006aee28a11f428a71bbfa8 "$test" | shasum -a 256 -c -
git rev-parse --verify "$base^{commit}" > "$out/parent-commit"
git rev-parse --verify "$(cat "$YAB_FARM_OUT/../snapshot")^{commit}" > "$out/candidate-snapshot"
[ "$(git rev-parse --verify "${REF:?farm ref required}^{commit}")" = "$(cat "$out/candidate-snapshot")" ]
git rev-parse HEAD > "$out/source-head"
git diff --quiet "$(cat "$out/candidate-snapshot")" -- Sources Resources Package.swift build.sh yab.entitlements "$test" "${controls[@]}"
git diff --quiet "$base" -- "${controls[@]}"
[ "$(git diff --name-only "$base" -- Sources Resources Package.swift build.sh yab.entitlements)" = "$path" ]
[ -z "$(git ls-files --others --exclude-standard -- Sources Resources)" ]
git diff --binary "$base" -- "$path" > "$out/candidate.patch"
shasum -a 256 "$test" "${controls[@]}" evals/feedback-754/remote_task_permit_pair.sh evals/golden/remote_task_provider_permit.sh > "$out/frozen-inputs.sha256"
cp "$path" "$out/candidate-source/$path"
restore() { cp "$out/candidate-source/$path" "$path"; }
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git show "$base:$path" > "$path"
git diff --quiet "$base" -- Sources Resources Package.swift build.sh yab.entitlements
run_tests() {
    local phase="$1"
    shasum -a 256 -c "$out/frozen-inputs.sha256"
    shasum -a 256 "$path" > "$out/$phase-source.sha256"
    printf '%s\n' "feedback754-permit-$phase-${SLOT:-$$}" > "$out/$phase-probe"
    local command=(swift test --jobs 2 --filter "$filter")
    [ "$phase" != after ] || command=(bash evals/golden/remote_task_provider_permit.sh)
    set +e
    YAB_PROBE="$(cat "$out/$phase-probe")" YAB_HISTORY=own "${command[@]}" 2>&1 | tee "$out/$phase.log"
    local codes=("${PIPESTATUS[@]}")
    set -e
    printf '%s\n' "${codes[0]}" > "$out/$phase.rc"
    printf '%s\n' "${codes[1]}" > "$out/$phase.tee-rc"
    shasum -a 256 -c "$out/frozen-inputs.sha256"
    python3 - "$out" "$phase" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
out, phase = pathlib.Path(sys.argv[1]), sys.argv[2]
names = set('''connectedTaskRetainsChosenProviderPermit disconnectedProviderIsRefused revokedProviderIsRefused disconnectAfterPreparationRefusesDispatch reconnectDoesNotReviveExistingTask revokedTurnRefusesDispatch staleMemoryEpochRefusesDispatch
aPreparedSessionHasItsImmutableOriginAndNoProcessUntilLaunched aStaleALateOrAPlacelessTaskIsRefusedWithWords itsAgentIsGivenOnlyTheReadOnlyServer everyCurrentBenchVerbAndUnknownVerbRefusesAllRemoteRequestRoutes directMCPTaskAndForeignTargetsCannotDetachTheActualInnerCaller localResumeQueueSteerSpawnAndAccessUpgradeDoNotReachAProvider anOrdinaryPositiveAlwaysPermitCannotWriteToTheRemoteProvider aRejectedFollowUpDoesNotAddAnUnsentTurn savedChatCodecAndLaterLocalMetadataCannotStripOrReplaceTheOrigin oldOrChangedReservationCannotCreateANewLocalSession
aCommittedMappingReservesOneFullUUIDAndNeverCopiesTheRequestWords cleanReopenKeepsTheConsumedSessionWithoutReissuingAClaim twoConnectionsCanReserveOnlyOneSessionBeforeAnyLaterAdapter staleBodyBeforeOrAfterReservationCannotRebindTheSession foreignWriterAccountMacSpaceCLIAndMemoryDatabaseHaveNoReservation aPreviouslyBoundAccountOrDeviceCannotReuseTheLedger ignoredOrAbortedReceiptAndScopeWritesFailClosedWithoutChangingOtherNamespaces
aCommittedCheckpointAndOutboxReopenTogetherAndReplayDoesNotAdvanceTheClock aTerminalActualResultCannotBeReplacedByALateStreamOrAReopen aReplicatedObservationCannotBecomeALocalEngineCheckpointWithoutProvenance aChangedRetainedRequestAndAWrongSessionNeverProduceAnOutboxCheckpoint abortAndIgnoreOnEitherDurableWriteRollbackBothCheckpointAndOutbox twoDatabaseConnectionsCannotCommitTwoDifferentFirstRevisions wrongAccountDeviceMemoryJournalAndCorruptLocalReceiptRefuse
requestAndResponsePoliciesRejectPostFilesCredentialsPopupsAndDownloads'''.split())
regression = 'connectedTaskRetainsChosenProviderPermit'
log = (out / f'{phase}.log').read_text(errors='replace')
code = int((out / f'{phase}.rc').read_text())
started = re.findall(r'◇ Test (\w+)\(\) started\.', log)
passed_raw = re.findall(r'✔ Test (\w+)\(\) passed ', log)
failed_raw = re.findall(r'✘ Test (\w+)\(\) failed ', log)
passed, failed = set(passed_raw), set(failed_raw)
summary = re.findall(r'Test run with (\d+) tests in (\d+) suites? (passed|failed)', log)
asserted = set(re.findall(r'✘ Test (\w+)\(\) recorded an issue[^\n]*Expectation failed:', log))
issues = re.findall(r'✘ Test (\w+)\(\) recorded an issue at RemoteTaskProviderPermitTests.swift:(\d+):\d+: ([^\n]*)', log)
test_lines = pathlib.Path('Tests/FastTests/RemoteTaskProviderPermitTests.swift').read_text().splitlines()
issue_sources = [(name, int(line), test_lines[int(line) - 1].strip(), message) for name, line, message in issues]
behavioral_only = len(issues) == log.count('recorded an issue') and all(name == regression and line in {96, 97, 98, 99, 100, 108, 109, 110} and '#expect(' in source and 'Expectation failed:' in message for name, line, source, message in issue_sources)
compiler_error = bool(re.search(r'\.swift:\d+(?::\d+)?: error:|error: (?:emit-module|fatalError|compile command|no tests found|Exited)|fatal error:|Build failed', log))
complete = len(names) == 32 and len(started) == 32 and set(started) == names and len(passed_raw) == len(passed) and len(failed_raw) == len(failed) and len(summary) == 1 and summary[0][:2] == ('32', '5')
behavior = code != 0 and failed == {regression} and asserted == {regression} and passed == names - {regression} and behavioral_only and (regression, 99) in {(name, line) for name, line, _, _ in issue_sources} if phase == 'before' else code == 0 and passed == names and not failed and not issues and not asserted and 'recorded an issue' not in log
valid = complete and behavior and not compiler_error and int((out / f'{phase}.tee-rc').read_text()) == 0 and summary[0][2] == ('failed' if phase == 'before' else 'passed')
def hashes(file):
    return {line.split(None, 1)[1].strip(): line.split()[0] for line in file.read_text().splitlines()}
report_path = out / 'summary.json'
report = json.loads(report_path.read_text()) if report_path.exists() else {}
parent = (out / 'parent-commit').read_text().strip()
path = 'Sources/Fast/Agents.swift'
report.update(parent_commit=parent, candidate_snapshot=(out / 'candidate-snapshot').read_text().strip(), source_head=(out / 'source-head').read_text().strip(), frozen_inputs_sha256=hashes(out / 'frozen-inputs.sha256'), expected_tests=sorted(names), expected_parent_failures=[regression], required_parent_issue=[regression, 99])
report['parent_source_sha256'] = {path: hashlib.sha256(subprocess.check_output(['git', 'show', f'{parent}:{path}'])).hexdigest()}
report['candidate_source_sha256'] = {path: hashlib.sha256((out / 'candidate-source' / path).read_bytes()).hexdigest()}
report[phase] = dict(rc=code, test_count=len(started), summary=summary, passed=sorted(passed), failed=sorted(failed), expectation_failures=sorted(asserted), issue_sources=issue_sources, compiler_error=compiler_error, valid=valid, source_sha256=hashes(out / f'{phase}-source.sha256'), probe=(out / f'{phase}-probe').read_text().strip())
report['status'] = 'blocked' if not valid else ('pass' if phase == 'after' and report.get('before', {}).get('valid') else 'before-validated')
report['scope'] = 'Constructor provider-permit capture and dispatch admission, six refusal/revocation controls, 25 remote task boundaries; candidate runs golden, no provider CLI/process, external network, app or reporter-profile claim.'
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
sys.exit(0 if valid else 2)
PY
}
run_tests before
restore
cmp "$path" "$out/candidate-source/$path"
git diff --quiet "$(cat "$out/candidate-snapshot")" -- Sources Resources Package.swift build.sh yab.entitlements
run_tests after
