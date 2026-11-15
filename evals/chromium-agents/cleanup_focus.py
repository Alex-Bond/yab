#!/usr/bin/env python3
"""Prove iframe draft cleanup without the independent video setup dependency."""
import argparse
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import threading
import time
import traceback
import uuid

EVALS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVALS))
sys.path.insert(0, str(EVALS / 'chromium-scripts'))
from agent_launch import launch_exact, require_window
from ownership import on_exit, record
import yab_socket


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    on_exit(out)
    spec = importlib.util.spec_from_file_location('original_cleanup', EVALS / 'agent-cleanup/check.py')
    original = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(original)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), original.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:' + str(server.server_port)
    world = 'chromium-cleanup-focus-' + uuid.uuid4().hex[:10]
    domain = 'dev.serafim.fast.test.' + world
    defaults = out / 'defaults.plist'
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True, timeout=15)
    summary = {'scope': 'Focused real-CEF plain/main/iframe draft cleanup only; not full lifecycle acceptance',
               'checks': {}, 'fixtures': {}, 'passed': False}
    proc = None
    ask = None
    try:
        env = dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE='chromium',
                   YAB_AGENT_CLAUDE='/nonexistent/chromium-claude', YAB_AGENT_CODEX='/nonexistent/chromium-codex')
        proc = record(launch_exact(args.app.resolve(), env, out, arguments=('-YabPageEngine', 'chromium')), out)
        sock = yab_socket.socket_path(world)
        ask = yab_socket.kwasker(sock, timeout=15, strict=True, takes_timeout=True,
                                fail=lambda request, reply: RuntimeError(f'{request}: {reply}'))

        def wait(check, label, seconds=45):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError('Exact app exited during ' + label)
                try:
                    value = check()
                    if value:
                        return value
                except (FileNotFoundError, ConnectionRefusedError):
                    pass
                time.sleep(.1)
            raise TimeoutError(label)

        wait(lambda: Path(sock).exists(), 'bench socket')
        require_window(ask)
        ask(do='agent-cleanup-preview', choice='fifteenMinutes')
        for name in ('plain', 'draft', 'frame-draft'):
            url = base + '/' + name
            tab = ask(do='agent-cleanup-preview', url=url)['tab']
            summary['fixtures'][name] = {'id': tab, 'url': url}
            # Observe the actual loaded document and fixture field. Never
            # navigate again, substitute content, or accept loading=false alone.
            condition = 'true' if name == 'plain' else (
                "document.getElementById('draft')?.value === 'Unsent draft'" if name == 'draft' else
                "document.querySelector('iframe')?.contentDocument?.getElementById('draft')?.value === 'Unsent draft'")
            script = 'location.href === ' + json.dumps(url) + " && document.readyState === 'complete' && (" + condition + ')'
            wait(lambda: ask(do='eval', id=tab, js=script).get('value') is True,
                 'actual fixture document ready: ' + name)
            native = ask(do='chromium', id=tab)
            assert native['engine'] == 'chromium', native
            summary['fixtures'][name]['engine'] = native['engine']
            print('fixture ready', name, tab, flush=True)

        def rows():
            return {row['id']: row for row in ask(do='agent-cleanup-preview')['tabs']}

        ask(do='agent-cleanup-preview', advance=0)
        ask(do='agent-cleanup-preview', advance=901)
        plain = summary['fixtures']['plain']['id']
        wait(lambda: plain not in rows(), 'finished temporary page closes')
        # Let every first inspection finish, including its two-second
        # fallback, before moving the clock for the next interval.
        time.sleep(2.5)
        state = rows()
        summary['checks']['finished temporary page closed'] = plain not in state
        summary['checks']['unsent form preserved'] = summary['fixtures']['draft']['id'] in state
        summary['checks']['draft inside an iframe preserved'] = summary['fixtures']['frame-draft']['id'] in state
        # Unknown answers get one interval, then close. A second full
        # interval distinguishes a proven busy draft from a timed-out check.
        ask(do='agent-cleanup-preview', advance=901)
        time.sleep(2.5)
        state = rows()
        summary['checks']['unsent form survives second interval'] = summary['fixtures']['draft']['id'] in state
        summary['checks']['iframe draft survives second interval'] = summary['fixtures']['frame-draft']['id'] in state
        summary['remaining'] = state
        summary['passed'] = all(summary['checks'].values())
        assert summary['passed'], summary['checks']
    except Exception:
        summary['error'] = traceback.format_exc()
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(summary, indent=2), flush=True)
        if ask is not None:
            try: ask(do='ui', act='quit')
            except Exception: pass
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=10)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
        server.shutdown()
        server.server_close()
        subprocess.run(['defaults', 'delete', domain], capture_output=True, timeout=15)


if __name__ == '__main__':
    main()
