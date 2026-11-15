#!/usr/bin/env python3
"""Additional original agent suites, sharing sweep's exact signed launcher."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
EVALS = HERE.parent
sys.path[:0] = [str(HERE), str(EVALS), str(EVALS / 'browse')]
import sweep
import yab_socket


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def keys(app, out, many):
    # The old base Yab builds an ad-hoc app around a copied binary. Replace
    # only construction/launch so its key UI and CLI assertions use sealed CEF.
    sync = load('check', EVALS / 'sync/check.py')

    def init(self, binary, scratch, label, server, standins=''):
        self.standins, self.server, self.pid = standins, server, None
        self.world = 'agentkeys-' + uuid.uuid4().hex[:10]
        self.app, self.bin = str(app), str(app / 'Contents/MacOS/yab')
        self.folder = str(Path(yab_socket.socket_path(self.world)).parent)
        self.sock = str(yab_socket.socket_path(self.world))
        for key in ('bench', 'welcomed'):
            subprocess.run(['defaults', 'write', 'dev.serafim.fast.test.' + self.world, key, '-bool', 'true'], check=True, timeout=15)

    sync.Yab.__init__ = init
    key = load('run', EVALS / 'agent-key/run.py')
    def start(self):
        # Settings' test-only key verifier sees made-up keys, never a provider.
        proc = sweep.probe_app.launch(app, {'YAB_PROBE': self.world, 'YAB_HISTORY': 'own',
            'HOME': self.home, 'YAB_AGENT_CLAUDE': self.claude, 'YAB_AGENT_KEY': key.KEY,
            'YAB_AGENT_KEY_CHECK': self.check}, out)
        self.pid = proc.pid
        yab_socket.wait_for(lambda: self.bench(do='census').get('pid'), 30)
    key.KeyYab.start = start
    sys.argv = [str(EVALS / 'agent-key' / ('many.py' if many else 'run.py')),
                '--bin', str(app / 'Contents/MacOS/yab'), '--out', str(out)]
    if many:
        runpy.run_path(sys.argv[0], run_name='__main__')
    else:
        key.main()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--suite', choices=('keys', 'many-keys', 'native', 'ask-motion', 'swarm'), required=True)
    args = parser.parse_args()
    app, out = args.app.resolve(), args.out.resolve()
    # Reuse the existing one-suite scope. It installs the exact launcher
    # before invoking this driver through runpy, with process cleanup receipts.
    if os.environ.get('CHROMIUM_AGENT_EXTRA_CHILD') != '1':
        sweep.SUITES[args.suite] = ('chromium-agents/extra.py', ['--out'], 1200)
        # Forward selection through this invocation's environment only.
        os.environ['CHROMIUM_AGENT_EXTRA_CHILD'] = '1'
        os.environ['CHROMIUM_AGENT_EXTRA_SUITE'] = args.suite
        # sweep.one invokes runpy with --app/--out; recover its suite below.
        sweep.one(args.suite, app, out)
        return
    if args.suite in ('keys', 'many-keys'):
        keys(app, out, args.suite == 'many-keys')
    elif args.suite == 'native':
        world = 'agent-native-' + uuid.uuid4().hex[:8]
        for name in ('bench', 'welcomed'):
            subprocess.run(['defaults', 'write', 'dev.serafim.fast.test.' + world, name, '-bool', 'true'], check=True, timeout=15)
        proc = sweep.probe_app.launch(app, {'YAB_PROBE': world, 'YAB_HISTORY': 'own'}, out)
        yab_socket.wait_for(lambda: Path(yab_socket.socket_path(world)).exists(), 30)
        import native
        native.run(str(proc.binary), world, str(out / 'captures'))
    elif args.suite == 'ask-motion':
        fixture = load('ask_motion_fixture', EVALS / 'ask-motion/check.py')
        assert fixture.run(str(app), out / 'after', 'Chromium'), 'Original native motion assertions failed'
        golden = load('agent_ask_motion_golden', EVALS / 'golden/agent_ask_motion.py')
        assert golden.verify(out / 'after'), 'Original golden fade assertions failed'
    elif args.suite == 'swarm':
        sys.argv = [str(EVALS / 'agent-swarm/run.py'), '--app', str(app), '--out', str(out)]
        runpy.run_path(sys.argv[0], run_name='__main__')
        # This recording script otherwise exits zero even after a failed
        # scenario. Preserve its contract and inspect actual scenario reports.
        contract = json.loads((out / 'contract.json').read_text())
        rows = [json.loads(line) for line in (out / 'summary.txt').read_text().splitlines()]
        assert contract['completed'] and len(rows) == 3 and not any('failed' in row for row in rows), rows
        (out / 'timing-limit.json').write_text(json.dumps({'exclusive': False,
            'performanceAccepted': False, 'reason': 'Shared farm run; functional contracts only'}))


if __name__ == '__main__':
    # sweep.one deliberately preserves the original eval's argv shape.
    if os.environ.get('CHROMIUM_AGENT_EXTRA_CHILD') == '1' and '--suite' not in sys.argv:
        sys.argv += ['--suite', os.environ['CHROMIUM_AGENT_EXTRA_SUITE']]
    main()
