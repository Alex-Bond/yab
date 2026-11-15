#!/usr/bin/env python3
"""Run existing agent lifecycle assertions on the exact signed Chromium app.

Only launch and capture are adapted. Original cases, checks and time limits
remain in their source files. Each suite runs in its own bounded process.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import sys
import uuid

EVALS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVALS))
sys.path.insert(0, str(EVALS / 'chromium-scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agent_launch import launch_exact, require_window
from ownership import record, on_exit
from probe_capture import picture
import probe_app
import yab_socket

SUITES = {'basics': 'agent-basics/check.py', 'cleanup': 'agent-cleanup/check.py'}


def one(suite, app, out):
    out.mkdir(parents=True, exist_ok=True)
    on_exit(out)
    socket.setdefaulttimeout(45)
    processes = []
    captures = []
    original_asker = yab_socket.asker

    def launch(source, env, evidence, extra_env_names=(), **options):
        assert Path(source).resolve() == app
        assert not options.get('bundle_id') and not options.get('arguments'), options
        env = dict(env, YAB_ENGINE='chromium', YAB_HEADLESS='0')
        if suite == 'basics':
            # The legacy suite predates explicit provider consent. Model a
            # connected synthetic CLI only in its fresh test defaults domain.
            # Every real provider remains unavailable to this app instance.
            domain = 'dev.serafim.fast.test.' + env['YAB_PROBE']
            home = out / 'fixture-home'
            home.mkdir()
            (home / '.claude.json').write_text(json.dumps({'oauthAccount': {
                'emailAddress': 'fixture@example.test', 'accountUuid': 'fixture'}}))
            env.update(HOME=str(home), ZDOTDIR=str(home), SHELL='/bin/sh', PATH='/usr/bin:/bin',
                       YAB_AGENT_CODEX='/nonexistent/chromium-codex',
                       YAB_AGENT_CURSOR='/nonexistent/chromium-cursor',
                       YAB_AGENT_GEMINI='/nonexistent/chromium-gemini')
            extra_env_names = (*extra_env_names, 'ZDOTDIR', 'SHELL', 'PATH')
            for key, values in {
                'agents.consent-migrated.v1': ['-bool', 'true'],
                'agents.explicit-connections.v1': ['-array', 'claude'],
                'agents.connection-generation.claude': [str(uuid.uuid4())],
            }.items():
                subprocess.run(['defaults', 'write', domain, key, *values], check=True)
        proc = record(launch_exact(app, env, Path(evidence), extra_env_names,
                                  ('-YabPageEngine', 'chromium')), out)
        processes.append(proc)
        return proc

    def asker(*args, **kwargs):
        ask = original_asker(*args, **kwargs)

        def call(request, *rest, **extra):
            # Native winshot omits the remotely composited Chromium page.
            # Keep the original screenshot/OCR assertions, using SCK pixels.
            if request.get('do') == 'winshot':
                proc = next(p for p in reversed(processes) if p.poll() is None)
                normal = require_window(lambda **req: ask(req))
                metadata = picture(proc.pid, request['path'], window_id=normal['number'])
                assert metadata.get('capture') == 'ScreenCaptureKit', metadata
                captures.append({'path': request['path'], 'capture': metadata})
                (out / 'sck-captures.json').write_text(json.dumps(captures, indent=2))
                return {'path': request['path']}
            # These are the test controller's person-side UI actions. They
            # must not borrow the target task's revoked tool admission.
            if suite == 'basics' and request.get('session') and request.get('do') in ('agent-wait', 'agent-chat', 'agent-stop'):
                request = dict(request)
                request['target'] = request.pop('session')
                request['verb'] = request['do']
                request['do'] = 'agent-fixture-control'
            reply = ask(request, *rest, **extra)
            if suite == 'basics' and request.get('do') == 'agent-fixture-control' and request.get('verb') == 'agent-stop' and reply.get('ok'):
                refused = ask({'do': 'agent-wait', 'session': request['target'], 'seconds': 0})
                assert 'expired' in refused.get('error', '').lower(), refused
                with (out / 'revoked-admission-checks.jsonl').open('a') as log:
                    log.write(json.dumps({'target': request['target'], 'refusal': refused, 'passed': True}) + '\n')
            return reply
        return call

    probe_app.launch = launch
    yab_socket.asker = asker
    # Legacy suites derive a world suffix from SLOT. Give each invocation
    # its own synthetic world rather than reusing another job's fixtures.
    os.environ['SLOT'] = uuid.uuid4().hex
    sys.argv = [str(EVALS / SUITES[suite]), '--app', str(app), '--out', str(out)]
    try:
        runpy.run_path(sys.argv[0], run_name='__main__')
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=10)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--suite', choices=SUITES)
    args = parser.parse_args()
    app, out = args.app.resolve(), args.out.resolve()
    if args.suite:
        one(args.suite, app, out)
        return
    out.mkdir(parents=True, exist_ok=True)
    results = {}
    for suite in SUITES:
        folder = out / suite
        folder.mkdir()
        command = [sys.executable, '-u', __file__, '--app', str(app), '--out', str(folder), '--suite', suite]
        with (folder / 'eval.log').open('w') as log:
            try:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=600, env=dict(os.environ, YAB_ENGINE='chromium'))
                results[suite] = {'passed': result.returncode == 0, 'exit': result.returncode}
            except subprocess.TimeoutExpired:
                results[suite] = {'passed': False, 'error': 'Suite exceeded 600 seconds'}
            finally:
                subprocess.run([sys.executable, str(EVALS / 'chromium-scripts/ownership.py'), str(folder)],
                               check=True, timeout=30)
        print(suite, json.dumps(results[suite]), flush=True)
        print((folder / 'eval.log').read_text(errors='replace')[-7000:], flush=True)
        (out / 'summary.json').write_text(json.dumps(results, indent=2))
    if not all(row['passed'] for row in results.values()):
        raise SystemExit('Chromium agent lifecycle acceptance failed')


if __name__ == '__main__':
    main()
