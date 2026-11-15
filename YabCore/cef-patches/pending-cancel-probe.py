#!/usr/bin/env python3
"""Held native CDP calls survive owner close/crash with exactly one failure."""
import argparse
import json
import os
from pathlib import Path
import traceback
from native_rpc import NativeRPC


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT'])
    report = {'checks': []}
    rpc = None

    def check(name, value, detail=None):
        report['checks'].append({'check': name, 'passed': bool(value), 'detail': detail})
        assert value, (name, detail)

    try:
        rpc = NativeRPC(args.app, out)
        rpc.call('profile.open', {'profile': 'cancel'})
        rpc.call('profile.open', {'profile': 'survivor'})
        survivor = rpc.call('tab.create', {'profile': 'survivor', 'url': 'data:text/html,<title>Survivor</title>'})['tab']
        rpc.ready(survivor)
        for operation in ['tab.close', 'page.crashForTesting']:
            owner = rpc.call('tab.create', {'profile': 'cancel', 'url': 'data:text/html,<title>Pending owner</title>'})['tab']
            rpc.ready(owner)
            rpc.js(owner, 'window.pendingStarted=0;return true')
            frame = next(c for c in rpc.contexts(owner) if c['main'] and c['default'])
            tokens = [rpc.send('scripts.evaluate', {
                'tab': owner, 'frame': frame['token'], 'world': '',
                'function': 'function(){window.pendingStarted++;return new Promise(()=>{})}',
                'arguments': None,
            }) for _ in range(8)]
            rpc.eventually('all native calls are actually pending',
                lambda: rpc.js(owner, 'return window.pendingStarted') == len(tokens))
            rpc.call(operation, {'tab': owner})
            for token in tokens:
                result = rpc.result(token, timeout=20, allow_error=True)
                check(operation + ' cancels held native call', 'error' in result, result)
            check(operation + ' leaves another browser usable',
                rpc.js(survivor, 'return document.title') == 'Survivor')
            for token in tokens:
                check(operation + ' responds exactly once',
                    sum(row.get('id') == token for row in rpc.history) == 1, token)
        rpc.shutdown()
        check('helper exits cleanly after cancellation', rpc.process.returncode == 0, rpc.process.returncode)
        report['passed'] = True
    except BaseException as error:
        report['error'] = repr(error) + '\n' + traceback.format_exc()
        raise
    finally:
        try:
            if rpc:
                rpc.close()
        finally:
            out.mkdir(parents=True, exist_ok=True)
            (out / 'pending-cancel.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
