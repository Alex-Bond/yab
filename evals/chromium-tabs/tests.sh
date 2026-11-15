#!/bin/bash
# Focused native tests, not a release gate. AppKit needs a synchronous loop.
set -euo pipefail
cd "$(dirname "$0")/../.."
# Non-display jobs do not export YAB_FARM_JOB. A full UUID plus the old
# prefix exceeded sockaddr_un.sun_path on the worker's Application Support path.
probe_token="${YAB_FARM_JOB:-$(uuidgen)}"
export YAB_PROBE="${YAB_TEST_PROBE:-chrtests-${probe_token:0:16}}"
export YAB_HISTORY=own
export CHROMIUM_TEST_FILTER="${1:-ChromiumPageTests|TabEngineTests|PageEngineTests}"
swift build --build-tests
# This is a read-only SwiftPM query, as in farm.py; it must not queue a
# second compiler lock after the actual --build-tests has completed.
BIN="$(/usr/bin/xcrun swift build --show-bin-path)"
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
result = subprocess.run([str(host), '--filter', os.environ.get('YAB_CHROMIUM_TEST_FILTER') or os.environ.get('CHROMIUM_TEST_FILTER', 'ChromiumPageTests|TabEngineTests|PageEngineTests'), '--no-parallel',
                         '--experimental-event-stream-output', str(out / 'focused.events.jsonl')], env=env)
raise SystemExit(result.returncode)
PY
