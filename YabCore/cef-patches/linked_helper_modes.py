#!/usr/bin/env python3
"""Retain both independent API-mode results; fail before any product build."""
import json
import os
from pathlib import Path
import subprocess
import sys


def run_modes(out, stable_api, *, run=subprocess.run, environment=None):
    if not 0 < stable_api < 999998:
        raise ValueError('Expected the measured stable SDK API version')
    out = Path(out)
    rows = []
    for mode, api in [('stable', stable_api), ('core', 999999)]:
        target = out / mode
        target.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ if environment is None else environment,
                   YAB_CEF_API_VERSION=str(api), YAB_FARM_OUT=str(target))
        row = {'mode': mode, 'apiVersion': api, 'commands': [], 'passed': False}
        try:
            command = ['bash', '-o', 'pipefail', 'YabCore/tests/job.sh']
            print('HELPER_API_MODE ' + mode, flush=True)
            code = run(command, env=env).returncode
            row['commands'].append({'step': 'build-client-protocol', 'exit': code})
            if code == 0:
                app = (target / 'app-path.txt').read_text().strip()
                if not app:
                    raise ValueError('Successful helper job did not retain its original app path')
                cancel = target / 'cancel'
                cancel.mkdir(parents=True, exist_ok=True)
                command = [sys.executable, '-u', 'YabCore/cef-patches/pending-cancel-probe.py', '--app', app]
                code = run(command, env=dict(env, YAB_FARM_OUT=str(cancel))).returncode
                row['commands'].append({'step': 'pending-cancel', 'exit': code})
            row['exit'] = code
        except (OSError, ValueError) as error:
            row.update(exit=125, error=str(error))
        row['passed'] = row['exit'] == 0 and len(row['commands']) == 2
        rows.append(row)
        (out / 'helper-api-modes.json').write_text(json.dumps({
            'modes': rows, 'complete': len(rows) == 2,
            'passed': len(rows) == 2 and all(item['passed'] for item in rows),
            'productAcceptance': False, 'completeProcessCleanupAccepted': False}, indent=2) + '\n')
    return next((row['exit'] for row in rows if row['exit']), 0)


if __name__ == '__main__':
    raise SystemExit(run_modes(os.environ['YAB_FARM_OUT'], int(sys.argv[1])))
