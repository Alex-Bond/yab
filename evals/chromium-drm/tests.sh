#!/bin/bash
# Focused native tests, not a release gate. AppKit needs a synchronous loop.
set -euo pipefail
cd "$(dirname "$0")/../.."
export YAB_PROBE="chromiumpage-tests-${YAB_FARM_JOB}"
export YAB_HISTORY=own
swift build --build-tests
BIN="$(swift build --show-bin-path)"
export CHROMIUM_TEST_BIN="$BIN"
python3 - <<'PY'
import os, pathlib, platform, subprocess
out = pathlib.Path(os.environ['YAB_FARM_OUT'])
bin = pathlib.Path(os.environ['CHROMIUM_TEST_BIN'])
choices = [p for name in ['FastTests', 'FastPackageTests']
           if (p := bin / (name + '.xctest') / 'Contents/MacOS' / name).is_file()]
if len(choices) != 1:
    raise RuntimeError('Expected exactly one current Fast test bundle: ' + str(choices))
sdk = pathlib.Path(subprocess.check_output(['xcrun', '--show-sdk-platform-path'], text=True).strip())
frameworks = sdk / 'Developer/Library/Frameworks'
rpaths = [frameworks, sdk / 'Developer/usr/lib', sdk / 'Developer/Library/PrivateFrameworks', sdk.parents[2] / 'SharedFrameworks']
host = out / 'swiftpm-testing-helper-chromium'
cmd = ['xcrun', 'swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.4', '-F', str(frameworks)]
for path in rpaths:
    cmd += ['-Xlinker', '-rpath', '-Xlinker', str(path)]
subprocess.run(cmd + ['scripts/runs/document_pip_test_entry.swift', '-o', str(host)], check=True)
env = dict(os.environ, YAB_DOCUMENT_PIP_TEST_BUNDLE=str(choices[0]))
result = subprocess.run([str(host), '--filter', os.environ['DRM_TEST_FILTER'], '--no-parallel',
                         '--experimental-event-stream-output', str(out / 'focused.events.jsonl')], env=env, timeout=600)
raise SystemExit(result.returncode)
PY
