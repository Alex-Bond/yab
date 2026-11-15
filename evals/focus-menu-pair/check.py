#!/usr/bin/env python3
"""Two native policy fixes, one warm incremental actual-main/candidate pair."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

args = argparse.ArgumentParser()
args.add_argument('--base', required=True)
options = args.parse_args()
if os.environ.get('YAB_FARM_WORKER') != '1':
    raise SystemExit('Run through the farm queue')
root = Path(__file__).resolve().parents[2]
os.chdir(root)
base = subprocess.check_output(['git', 'rev-parse', options.base + '^{commit}'], text=True).strip()
out = Path(os.environ['YAB_FARM_OUT']) / 'focus-menu-pair'
out.mkdir(exist_ok=False)
changed = ['Sources/Fast/Browser.swift', 'Sources/Fast/TabBar.swift']
kept = {name: Path(name).read_bytes() for name in changed}
tracked = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', base, '--', 'Sources', 'Package.swift', 'Package.resolved'], text=True).splitlines()
actual_sources = {str(p) for p in Path('Sources').rglob('*') if p.is_file()}
expected_sources = {name for name in tracked if name.startswith('Sources/')}
assert actual_sources == expected_sources, 'Sources inventory differs from actual main'
baseline = {name: subprocess.check_output(['git', 'show', base + ':' + name]) for name in tracked}
for name, data in baseline.items():
    if name not in changed:
        assert Path(name).read_bytes() == data, 'Foreign source differs: ' + name
base_hashes = {name: hashlib.sha256(data).hexdigest() for name, data in baseline.items()}
report = {'base': base, 'sourceBaselineSHA256': base_hashes, 'changedSources': changed, 'runs': {},
          'scope': '1148 selected agent-created popup focus;1194 passive target-tab context-menu actions',
          'limits': 'Explicit engine metadata and native NSHostingMenu handlers; no physical WebKit modifiers or matching reporter profile.'}
pattern = 'AgentPopupFocusTests|TabMenuPassiveTests|ModifiedLinkFocusTests|LinkMenuFocusTests|LinkPeekRoutingTests|LinkFoldersTests|TabPlacementTests'
env = dict(os.environ, YAB_PROBE='focus-menu-' + os.environ.get('YAB_FARM_JOB', 'golden'), YAB_HISTORY='own')
command = ['swift', 'test', '--scratch-path', '.build/dev-optimized', '-c', 'debug', '-Xswiftc', '-O',
           '--jobs', os.environ.get('YAB_JOBS', '2'), '--no-parallel', '--filter', pattern]

def run(label):
    with (out / (label + '.log')).open('w') as log:
        child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in child.stdout:
            print(line, end='', flush=True)
            log.write(line)
        rc = child.wait()
    text = (out / (label + '.log')).read_text()
    assert rc in (0, 1), label + ' did not finish assertions: ' + str(rc)
    assert re.search(r'Test run with \d+ tests?.*(?:passed|failed)', text), label + ' incomplete'
    assert 'unexpected signal' not in text, label + ' crashed'
    report['runs'][label] = {'exit': rc, 'log': str(out / (label + '.log'))}
    (out / 'result.json').write_text(json.dumps(report, indent=2))
    return rc, text

try:
    for name in changed:
        Path(name).write_bytes(baseline[name])
    for name, data in baseline.items():
        assert Path(name).read_bytes() == data, 'Before differs from main: ' + name
    before, before_text = run('before')
    assert before == 1, 'Actual main unexpectedly passed'
    assert 'selectedAgentPageHonorsExplicitInput' in before_text and 'AgentPopupFocusTests.swift:' in before_text, 'Agent focus counterexample absent'
    assert 'must not select its target' in before_text, 'Passive menu counterexample absent'
finally:
    for name, data in kept.items():
        Path(name).write_bytes(data)
after, after_text = run('after')
report['pass'] = after == 0
(out / 'result.json').write_text(json.dumps(report, indent=2))
assert after == 0, 'Candidate did not pass all focus/menu guards'
