#!/usr/bin/env python3
"""Draft signed-app proof for the next connected-mail routing batch.

Run only in a farm job, with --repo naming that job's source tree. The paired
job must bind --expect-main-refusal to the actual c31305f5 app, never to a
patched tree with a change removed. All mail and codes are synthetic.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import threading
import time
import uuid

CODE = '604418'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--engine', choices=('webKit', 'chromium'), required=True)
    parser.add_argument('--expect-main-refusal', action='store_true')
    args = parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER') != '1':
        raise SystemExit('Run this signed-app fixture through the farm')
    assert not args.expect_main_refusal or args.engine == 'chromium'
    root, app, out = args.repo.resolve(), args.app.resolve(), args.out.resolve()
    sys.path[:0] = [str(root / 'evals/chromium-agents'), str(root / 'evals'),
                   str(root / 'evals/browse'), str(root / 'evals/mail')]
    from agent_launch import launch_exact, require_window, require_page_window
    from ownership import record, on_exit
    from probe_capture import picture
    from fake_gmail import FakeGmail
    import prims
    import yab_socket

    out.mkdir(parents=True, exist_ok=True)
    on_exit(out)
    report = {'engine': args.engine, 'app': str(app), 'syntheticOnly': True,
              'expectedMainRefusal': args.expect_main_refusal, 'checks': []}
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    report['inputBinarySHA256'] = hashlib.sha256((app / 'Contents/MacOS' / info['CFBundleExecutable']).read_bytes()).hexdigest()

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<!doctype html><title>Local mail-code fixture</title><h1>Local mail-code fixture</h1><p>Synthetic connected-mail routing check.</p>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass

    pages = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page)
    fake = FakeGmail(me='agent-code-fixture@example.test')
    fake.add('synthetic-code', 'Local Test <codes@127.0.0.1>',
             'Your sign-in code', 'Your code is ' + CODE + '.', ['INBOX', 'UNREAD'])
    gmail = fake.server(0)
    for server in (pages, gmail):
        threading.Thread(target=server.serve_forever, daemon=True).start()

    def check(name, ok, detail):
        report['checks'].append({'name': name, 'passed': bool(ok), 'detail': detail})
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        assert ok, (name, detail)

    def phase(label, connected=True, enabled=True):
        folder = out / label
        folder.mkdir()
        world = 'agent-mail-code-' + uuid.uuid4().hex[:10]
        domain = 'dev.serafim.fast.test.' + world
        defaults = folder / 'defaults.plist'
        defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False,
            'codes.mail': enabled, 'agents.asking': 'bypass', 'hints.noticing': False}))
        subprocess.run(['defaults', 'import', domain, str(defaults)], check=True, timeout=15)
        proc = record(launch_exact(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own',
            YAB_ENGINE=args.engine, YAB_AGENT_CLAUDE='/usr/bin/true',
            YAB_AGENT_CODEX='/nonexistent/fixture-codex'), folder), folder)
        m = None
        try:
            ask = yab_socket.asker(yab_socket.socket_path(world), timeout=30)
            yab_socket.wait_for(lambda: ask({'do': 'census'}).get('pid'), 40)
            if connected:
                added = ask({'do': 'agent-mail-account', 'account': fake.me,
                             'base': f'http://127.0.0.1:{gmail.server_port}/gmail/v1/users/me/'})
                check(label + ': synthetic account connected', added.get('ok') is True, added)
                state = yab_socket.wait_for(lambda: (lambda r: r if r.get('synced', 0) > 0 else None)(
                    ask({'do': 'agent-mail-state'})), 40)
                check(label + ': fake mailbox synced', fake.me in state.get('accounts', []), state)
            m = prims.Mcp(str(proc.binary), world)
            if not enabled:
                check('disabled preference removes mail_code', 'mail_code' not in m.tools, sorted(m.tools))
                return
            check(label + ': mail_code listed', 'mail_code' in m.tools, sorted(m.tools))
            opened = m('open', url=f'http://127.0.0.1:{pages.server_port}/')
            tab = prims.tab_of(opened)
            state = next(row for row in ask({'do': 'dark'})['tabs'] if row['id'] == tab)
            check(label + ': actual page engine', state['engine'] == args.engine, state)
            raw = m.call_raw('tools/call', {'name': 'mail_code', 'arguments': {'tab': tab}})
            said = '\n'.join(c.get('text', '') for c in raw.get('content', []) if c.get('type') == 'text')
            def capture(name):
                m('show', tab=tab)
                normal = require_window(lambda **request: ask(request))
                if args.engine == 'chromium':
                    normal = require_page_window(lambda **request: ask(request), tab)
                number = normal['window'] if 'window' in normal else normal['number']
                metadata = picture(proc.pid, folder / (name + '.png'), window_id=number)
                check(name + ': actual signed-app window captured', metadata.get('capture') == 'ScreenCaptureKit', metadata)
            if args.expect_main_refusal or not connected:
                check(label + ': exact WK-store refusal', raw.get('isError') and 'the tab has no page yet' in said,
                      {'reply': raw, 'scope': 'expected main failure' if connected else 'unconnected native fallback remains unavailable'})
                capture('main-refusal' if connected else 'unconnected-refusal')
                return
            check('connected MailCenter returns the synthetic code', not raw.get('isError') and CODE in said, raw)
            other = prims.tab_of(m('open', url=f'http://localhost:{pages.server_port}/'))
            wrong = m('mail_code', tab=other)
            check('wrong host cannot read the code', wrong.startswith('No code from ') and CODE not in wrong, wrong)
            capture('connected-mail')
        finally:
            if m is not None:
                m.close()
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)

    try:
        phase('connected')
        if not args.expect_main_refusal:
            phase('disabled', enabled=False)
            if args.engine == 'chromium':
                phase('unconnected', connected=False)
        report['outcome'] = 'expected-main-failure' if args.expect_main_refusal else 'passed'
    finally:
        for server in (pages, gmail):
            server.shutdown()
            server.server_close()
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
