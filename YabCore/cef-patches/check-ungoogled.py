#!/usr/bin/env python3
"""Read-only conflict probe of the nearest ungoogled patch stack.

A conflict is sufficient to reject this optional stack. Independent clean
checks are not sufficient to approve it; full sequential application would
still need an isolated source tree after the baseline CEF build.
"""
import json
import os
from pathlib import Path
import subprocess
import urllib.request

revision = '0673f8701c94e5688c33ef8ce5e36602d311d246'
base = f'https://raw.githubusercontent.com/ungoogled-software/ungoogled-chromium/{revision}/'
out = Path(os.environ['YAB_FARM_OUT'])
src = Path(os.environ.get('YAB_CHROMIUM_SRC', str(Path.home() / 'chromium/src')))

def fetch(relative):
    with urllib.request.urlopen(base + relative, timeout=60) as response:
        return response.read()

series = fetch('patches/series').decode()
(out / 'series.txt').write_text(series)
result = {'version': '156.0.8078.47-1', 'revision': revision, 'applied': False,
          'status': 'requires-isolated-sequential-check', 'checked': []}
for line in series.splitlines():
    name = line.split('#', 1)[0].strip()
    if not name:
        continue
    if len(name.split()) != 1 or '..' in Path(name).parts:
        raise SystemExit('Unexpected patch series entry')
    patch = out / Path(name).name
    patch.write_bytes(fetch('patches/' + name))
    check = subprocess.run(['git', '-C', str(src), 'apply', '--check', str(patch)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    result['checked'].append({'patch': name, 'clean': check.returncode == 0})
    if check.returncode:
        result['status'] = 'conflict'
        result['firstConflict'] = name
        result['diagnostic'] = check.stdout
        print(check.stdout, end='')
        break
(out / 'ungoogled-check.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
