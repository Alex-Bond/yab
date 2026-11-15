#!/usr/bin/env python3
"""Run legacy agent eval assertions on one sealed CEF app, with bounded steps.

The adapter changes only launch/capture and records synthetic connection
preconditions. Each original eval runs in a separate process. Real-account
and keychain suites remain explicit blockers, never silently counted as passes.
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

HERE = Path(__file__).resolve().parent
EVALS = HERE.parent
sys.path[:0] = [str(HERE), str(EVALS), str(EVALS / 'chromium-scripts')]
from agent_launch import launch_exact, require_window
from probe_capture import picture
from ownership import record, on_exit
import probe_app
import yab_socket

SUITES = {
    'made': ('agent-made/check.py', ['--out'], 360),
    'row': ('agent-row/check.py', [], 360),
    'providers': ('agent-providers/check.py', ['--out'], 600),
    'gemini-connect': ('agent-providers/gemini_connect.py', ['--out'], 240),
    'cli-launch': ('agent-cli-launch/check.py', ['--out'], 300),
    'plaque': ('agent-plaque/check.py', ['--out'], 180),
    'face-slide': ('agent-face-slide/shoot.py', [], 300),
    'row-hush': ('golden/agent_row_hush.py', ['--out'], 300),
    'needs-user': ('agent-needs-user/check.py', ['--bin', '--out'], 180),
    'cleanup-focused': ('chromium-agents/cleanup_focus.py', ['--out'], 240),
    'golden-secrets': ('golden/chromium_agent_secrets.py', ['--out'], 1500),
}


def one(name, app, out):
    out.mkdir(parents=True, exist_ok=True)
    on_exit(out)
    socket.setdefaulttimeout(45)
    os.environ.update(YAB_ENGINE='chromium', YAB_AGENT_CEF_CAPTURE='1', YAB_FARM_OUT=str(out),
                      APP=str(out / (os.environ['YAB_TASK_NAME'] + '.app')), SLOT=uuid.uuid4().hex)
    processes = []
    launches = []
    captures = []
    original_asker = yab_socket.asker

    def asker(*args, **kwargs):
        ask = original_asker(*args, **kwargs)
        def call(request, *rest, **extra):
            if request.get('do') == 'winshot':
                proc = next(p for p in reversed(processes) if p.poll() is None)
                normal = ask({'do': 'window'})
                if len(normal.get('frame', [])) != 4:
                    normal = require_window(lambda **req: ask(req))
                metadata = picture(proc.pid, request['path'], window_id=normal['number'])
                assert metadata.get('capture') == 'ScreenCaptureKit', metadata
                captures.append({'path': request['path'], 'capture': metadata})
                (out / 'sck-captures.json').write_text(json.dumps(captures, indent=2))
                return {'path': request['path']}
            controlled = (name in ('made', 'row', 'providers') and request.get('session')
                          and request.get('do') in ('agent-wait', 'agent-chat', 'agent-stop'))
            if not controlled:
                return ask(request, *rest, **extra)
            values = dict(request)
            target = values.pop('session')
            verb = values['do']
            values.update(do='agent-fixture-control', target=target, verb=verb)
            reply = ask(values, *rest, **extra)
            if verb == 'agent-stop' and reply.get('ok'):
                refused = ask({'do': 'agent-wait', 'session': target, 'seconds': 0})
                assert 'expired' in refused.get('error', '').lower(), refused
                with (out / 'revoked-admission.jsonl').open('a') as log:
                    log.write(json.dumps({'target': target, 'refusal': refused, 'passed': True}) + '\n')
            return reply
        return call

    def launch(source, env, evidence, extra_env_names=(), **options):
        assert Path(source).resolve() == app, source
        assert not options.get('bundle_id') and not options.get('arguments'), options
        evidence = Path(evidence)
        evidence.mkdir(parents=True, exist_ok=True)
        env = dict(env, YAB_ENGINE='chromium', YAB_HEADLESS='0')
        if name in ('made', 'row', 'providers'):
            # These fixtures predate explicit provider consent. Connect only
            # their stand-in executable in this new test world's settings.
            domain = 'dev.serafim.fast.test.' + env['YAB_PROBE']
            home = out / ('fixture-home-' + str(len(launches)))
            home.mkdir()
            (home / '.claude.json').write_text(json.dumps({'oauthAccount': {
                'emailAddress': 'fixture@example.test', 'accountUuid': 'fixture'}}))
            env.update(HOME=str(home), ZDOTDIR=str(home), SHELL='/bin/sh', PATH='/usr/bin:/bin')
            extra_env_names = (*extra_env_names, 'ZDOTDIR', 'SHELL', 'PATH')
            providers = [key.removeprefix('YAB_AGENT_').lower() for key, path in env.items()
                         if key in ('YAB_AGENT_CLAUDE', 'YAB_AGENT_GEMINI', 'YAB_AGENT_CURSOR')
                         and Path(path).is_file()]
            for key, values in {
                'agents.consent-migrated.v1': ['-bool', 'true'],
                'agents.explicit-connections.v1': ['-array', *providers],
                **{'agents.connection-generation.' + provider: [str(uuid.uuid4())] for provider in providers},
            }.items():
                subprocess.run(['defaults', 'write', domain, key, *values], check=True, timeout=15)
        else:
            providers = []
        target = out / ('launch-' + str(len(launches)))
        target.mkdir()
        proc = record(launch_exact(app, env, target, extra_env_names,
                     ('-YabPageEngine', 'chromium')), target)
        processes.append(proc)
        launches.append({'pid': proc.pid, 'engine': 'chromium', 'app': str(app),
                         'world': env['YAB_PROBE'], 'syntheticConnectedProviders': providers})
        (out / 'exact-launches.json').write_text(json.dumps(launches, indent=2))
        return proc

    probe_app.launch = launch
    yab_socket.asker = asker
    path, flags, _ = SUITES[name]
    sys.argv = [str(EVALS / path)]
    sys.argv += ['--bin', str(app / 'Contents/MacOS/yab')] if '--bin' in flags else ['--app', str(app)]
    if '--out' in flags:
        sys.argv += ['--out', str(out)]
    try:
        runpy.run_path(sys.argv[0], run_name='__main__')
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=10)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--suite', choices=SUITES)
    parser.add_argument('--only', default=','.join(SUITES))
    args = parser.parse_args()
    app, out = args.app.resolve(), args.out.resolve()
    if args.suite:
        one(args.suite, app, out)
        return
    out.mkdir(parents=True, exist_ok=True)
    results = {}
    for name in args.only.split(','):
        path, _, budget = SUITES[name]
        folder = out / name
        folder.mkdir()
        command = [sys.executable, '-u', __file__, '--app', str(app), '--out', str(folder), '--suite', name]
        with (folder / 'eval.log').open('w') as log:
            try:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=budget, env=dict(os.environ, YAB_ENGINE='chromium')).returncode
                results[name] = {'eval': path, 'passed': rc == 0, 'exit': rc}
            except subprocess.TimeoutExpired:
                results[name] = {'eval': path, 'passed': False, 'error': f'Suite exceeded {budget} seconds'}
            finally:
                subprocess.run([sys.executable, str(EVALS / 'chromium-scripts/ownership.py'), str(folder)],
                               check=True, timeout=60)
        print(name, json.dumps(results[name]), flush=True)
        print((folder / 'eval.log').read_text(errors='replace')[-4500:], flush=True)
        (out / 'summary.json').write_text(json.dumps(results, indent=2))
    if not all(row['passed'] for row in results.values()):
        raise SystemExit('Agent parity sweep failed')


if __name__ == '__main__':
    main()
