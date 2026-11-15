#!/usr/bin/env python3
"""Continue this owned baseline after its already-running dependency sync.

The blocking lock waits for our sync process to exit; no farm jobs or Mac
processes are involved. Every next stage stops on the first actual failure.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stages', nargs='+', choices=('tools', 'hooks', 'generate', 'build'),
                        default=['tools', 'hooks', 'generate', 'build'])
    args = parser.parse_args()
    root = Path('/data/yab-chromium-baseline')
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('Only the owned Linux x86_64 environment is supported.')
    if json.loads((root / 'owner.json').read_text()).get('task') != 'yab-android-chromium-20261022':
        raise RuntimeError('Unexpected directory owner; preserve it.')
    files = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
             for name in ('baseline.json', 'bootstrap.py')}
    receipt = {'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'waitingFor': 'sync', 'inputHashes': files, 'stages': [], 'exitCode': None}
    target = root / 'continuation-receipt.json'

    def save():
        temporary = target.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(receipt, indent=2) + '\n')
        temporary.replace(target)

    save()
    with (root / 'baseline.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sync = json.loads((root / 'sync-receipt.json').read_text())
        if not sync.get('completed') or sync.get('exitCode') != 0:
            receipt.update({'exitCode': 1, 'error': 'Dependency sync did not succeed; no hooks or build started.'})
            save()
            return 1
        receipt['syncReceiptStartedAt'] = sync['startedAt']
        receipt['waitingFor'] = None
        save()
    for stage in args.stages:
        if any(hashlib.sha256((root / name).read_bytes()).hexdigest() != expected
               for name, expected in files.items()):
            receipt.update({'exitCode': 1, 'error': 'Baseline inputs changed; do not continue silently.'})
            save()
            return 1
        item = {'stage': stage, 'exitCode': None}
        receipt['stages'].append(item)
        save()
        result = subprocess.run([sys.executable, str(root / 'bootstrap.py'), '--root', str(root), '--stage', stage],
                                cwd=root)
        item['exitCode'] = result.returncode
        if result.returncode:
            receipt['exitCode'] = result.returncode
            save()
            return result.returncode
        save()
    receipt.update({'exitCode': 0, 'finishedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()})
    save()
    return 0


if __name__ == '__main__':
    sys.exit(main())
