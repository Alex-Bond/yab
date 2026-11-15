#!/usr/bin/env python3
"""Keep legacy browse assertions, replacing their bare GUI binary launch only."""
import argparse
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import sys

HERE = Path(__file__).resolve().parent
EVALS = HERE.parent
sys.path[:0] = [str(HERE), str(EVALS / 'browse'), str(EVALS), str(EVALS / 'chromium-scripts')]
from agent_launch import launch_exact
from ownership import record, on_exit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--suite', choices=('spaces', 'gates'), required=True)
    args = parser.parse_args()
    app, out = args.app.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    on_exit(out)
    socket.setdefaulttimeout(45)
    original = subprocess.Popen
    launches = []
    processes = []

    def popen(command, *rest, **kw):
        env = kw.get('env', {})
        if isinstance(command, list) and len(command) == 1 and env.get('YAB_PROBE'):
            target = out / ('launch-' + str(len(launches)))
            target.mkdir()
            proc = record(launch_exact(app, dict(env, YAB_ENGINE='chromium'), target,
                         arguments=('-YabPageEngine', 'chromium')), target)
            processes.append(proc)
            launches.append({'originalExecutable': command[0], 'actualApp': str(app),
                             'pid': proc.pid, 'world': env['YAB_PROBE'], 'engine': 'chromium'})
            (out / 'exact-launches.json').write_text(json.dumps(launches, indent=2))
            return proc
        return original(command, *rest, **kw)

    subprocess.Popen = popen
    sys.argv = [str(EVALS / 'browse' / (args.suite + '.py')), '--bin', str(app / 'Contents/MacOS/yab')]
    try:
        runpy.run_path(sys.argv[0], run_name='__main__')
    finally:
        subprocess.Popen = original
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=10)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)


if __name__ == '__main__':
    main()
