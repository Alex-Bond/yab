#!/usr/bin/env python3
"""Focused native menu and existing userscript file-to-card tests, on the farm."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
if os.environ.get('YAB_FARM_WORKER') != '1':
    raise SystemExit('Run through ./farm')
manifest = root / 'Package.swift'
original = manifest.read_text()
marker = '            path: "Tests/FastTests",\n'
assert original.count(marker) == 1
sources = ['BoostAddMenuTests.swift', 'UserscriptAddTests.swift', 'UserscriptTests.swift']
excluded = sorted(p.name for p in (root / 'Tests/FastTests').iterdir() if p.name not in sources)
selection = '            exclude: ' + json.dumps(excluded) + ',\n'
selection += '            sources: ' + json.dumps(sources) + ',\n'
try:
    manifest.write_text(original.replace(marker, marker + selection))
    result = subprocess.run(['swift', 'test', '--scratch-path', '.build/dev-optimized', '-c', 'debug',
                             '-Xswiftc', '-O', '--filter', 'BoostAddMenuTests|UserscriptAddTests'], cwd=root,
                            env=dict(os.environ, YAB_PROBE='boost-add-unit', YAB_AGENTS='none'))
finally:
    manifest.write_text(original)
raise SystemExit(result.returncode)
