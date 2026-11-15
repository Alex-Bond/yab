#!/usr/bin/env python3
"""Synthetic sign-in cookies across restart and live engine switches. Farm only."""
import argparse
import http.server
import json
import os
from pathlib import Path
import plistlib
import subprocess
import ssl
import sys
import threading
import uuid
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-tabs'))
from run import wait_for
from probe_app import OwnedApp, _same
from probe_capture import picture
import yab_socket


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        value = query.get('set', [None])[0]
        body = ('''<!doctype html><meta charset="utf-8"><title>Switch cookies</title>
<style>body{margin:40px;background:#164b38;color:white;font:24px system-ui;height:3000px}header{position:fixed;top:25px;background:#164b38}input{font:inherit}</style>
<header><h1 id="engine"></h1><p>Synthetic sign-in. No real account.</p><pre id="state"></pre><input id="draft" aria-label="Draft"><input id="secret" type="password" aria-label="Secret"></header>
<script>document.querySelector('#engine').textContent=navigator.userAgent.includes('Chrome/')?'Chromium':'WebKit';
window.requestCookies=COOKIE; window.bootStorage=[localStorage.getItem('switch-local'),sessionStorage.getItem('switch-session')];
document.querySelector('#state').textContent='Initial request: '+window.requestCookies+'\\nStorage at boot: '+JSON.stringify(window.bootStorage);</script>'''
                .replace('COOKIE', json.dumps(self.headers.get('Cookie', '')))).encode()
        self.send_response(200)
        if value is not None:
            age = '0' if value == 'delete' else '86400'
            self.send_header('Set-Cookie', f'switch_http={value}; Path=/; Max-Age={age}; HttpOnly; SameSite=Lax')
            self.send_header('Set-Cookie', f'switch_js={value}; Path=/; Max-Age={age}; SameSite=Lax')
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(app, out, site, tls_site):
    assert os.environ.get('YAB_FARM_WORKER') == '1'
    out.mkdir(parents=True, exist_ok=True)
    world = 'switch-' + uuid.uuid4().hex[:10]
    domain = 'dev.serafim.fast.test.' + world
    sock = Path.home() / 'Library/Application Support' / f'Yab ({world})' / 'bench.sock'
    defaults = out / 'defaults.plist'
    permission_seed = {f'capture.{site}|{kind}': False for kind in range(3)}
    permission_seed.update({'location.127.0.0.1': False, 'notifications.' + site: False})
    defaults.write_bytes(plistlib.dumps({**permission_seed, 'bench': True, 'welcomed': True, 'mail': False,
        'hints.noticing': False, 'searchSuggest': False, 'ApplePersistenceIgnoreState': True,
        'NSQuitAlwaysKeepsWindows': False}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True, timeout=30)
    report = {'world': world, 'checks': {}, 'pictures': [], 'states': {}}
    checks = report['checks']
    proc = None
    ask = None
    quits = 0

    def launch(kind):
        nonlocal proc, ask
        phase = out / kind
        phase.mkdir(exist_ok=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, timeout=60)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
        env = dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE=kind,
            YAB_AGENT_CLAUDE='/usr/bin/true', YAB_AGENT_CODEX='/nonexistent/chromium', YAB_SWITCH_COOKIE_SYNC='manual', YAB_SWITCH_ISOLATE_WEBKIT='1')
        command = ['open', '-g', '-n', '-a', str(app), '--stdout', str(phase / 'browser.log'),
            '--stderr', str(phase / 'browser.log')]
        for name, value in env.items():
            if name.startswith('YAB_'): command += ['--env', name + '=' + value]
        command += ['--args', '-YabPageEngine', kind]
        subprocess.run(command, check=True, timeout=30)
        def owned():
            rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=10).splitlines()
            for row in rows:
                fields = row.strip().split(None, 1)
                if len(fields) == 2 and _same(fields[1], binary): return OwnedApp(int(fields[0]), binary)
            return None
        proc = wait_for(owned, 'Exact signed switch app did not launch', 30)
        ask = yab_socket.kwasker(sock, timeout=45, strict=True, takes_timeout=True,
            fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
        # A previous graceful app leaves its socket path behind. Require a
        # live response from this launch, not merely the old filesystem entry.
        def live_bench():
            if proc.poll() is not None:
                raise RuntimeError('Signed switch app exited during startup')
            try:
                return ask(do='chromium-drm', op='switch-isolation')
            except (ConnectionRefusedError, FileNotFoundError):
                return None
        isolation = wait_for(live_bench, 'Missing live bench socket', 60)
        if not isolation['isolated']:
            raise RuntimeError('Switch probe is not using its isolated WebKit store')
        ask(do='ui', welcome=False, sidebar=True)
        ask(do='usage-background', hide=False)

    def stop():
        nonlocal proc, quits
        if proc is None:
            return
        try:
            ask(do='quit-ask', yes=True)
        except Exception:
            pass
        quits += 1
        try:
            proc.wait(timeout=20)
            checks['graceful_quit_' + str(quits)] = True
        except subprocess.TimeoutExpired:
            checks['graceful_quit_' + str(quits)] = False
            proc.terminate()
            try: proc.wait(timeout=10)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
        proc = None

    def ready(tab, kind):
        def poll():
            state = ask(do='chromium-drm', id=tab)
            report['states']['last'] = state
            return state if (state['engine'] == kind and not state['loading'] and state['title'] == 'Switch cookies'
                and (kind != 'chromium' or state['context'] > 0)) else None
        return wait_for(poll, 'Switch page not ready: ' + kind, 60)

    def script(tab, body):
        return ask(do='chromium-drm', id=tab, op='script', body=body)['value']

    def capture(tab, name):
        ask(do='select', id=tab)
        state = wait_for(lambda: (s if (s := ask(do='chromium-drm', id=tab))['window'] > 0 else None), 'No attached window')
        path = out / (name + '.png')
        meta = picture(proc.pid, path, window_id=state['window'])
        report['pictures'].append({'file': path.name, 'capture': meta})
        checks[name + '_sck'] = meta.get('capture') == 'ScreenCaptureKit'

    def assert_site_decisions(tab, notifications, label):
        # Read real Site Controls facts in each engine. These synthetic site
        # decisions never request or change an operating-system permission.
        ask(do='select', id=tab)
        facts = ask(do='site-facts')
        report['states'][label + '_permissions'] = facts['allowed']
        choices = {row['title']: row['said'] for row in facts['allowed']}
        for title in ['Camera', 'Microphone', 'Camera and microphone', 'Location']:
            checks[label + '_' + title.lower().replace(' ', '_')] = choices.get(title) == 'Blocked'
        checks[label + '_notifications'] = choices.get('Notifications') == notifications

    def assert_cookies(tab, value, label):
        current = script(tab, 'return {request:window.requestCookies,js:document.cookie}')
        report['states'][label] = current
        if value is None:
            checks[label] = 'switch_http=' not in current['request'] and 'switch_js=' not in current['js']
        else:
            checks[label] = (f'switch_http={value}' in current['request'] and f'switch_js={value}' in current['js']
                and 'switch_http=' not in current['js'])

    try:
        # Seed a real WebKit website store without ever creating a Chromium
        # bridge. Its first Chromium request must already carry both cookies.
        launch('webKit')
        tab = ask(do='usage-open', url=site + '/seed')['id']
        ready(tab, 'webKit')
        script(tab, "await fetch('/?set=webkit');document.querySelector('#state').textContent='Seeded WebKit profile: '+document.cookie;return true")
        seed_id = tab
        assert_site_decisions(tab, 'Blocked', 'webkit_seed')
        # Write an app-owned site decision while WebKit is active.
        ask(do='ui', notify='allow:' + site)
        checks['webkit_seed'] = 'switch_js=webkit' in script(tab, 'return document.cookie')
        capture(tab, '01-webkit-seed')
        stop()
        launch('chromium')
        restored = ask(do='tabs')['tabs']
        report['states']['restored_tabs'] = restored
        checks['global_restart_keeps_tab'] = any(row['id'].lower() == seed_id.lower() and row['url'] == site + '/seed' for row in restored)
        tab = ask(do='usage-open', url=site + '/first')['id']
        ready(tab, 'chromium')
        assert_cookies(tab, 'webkit', 'first_chromium_request')
        assert_site_decisions(tab, 'Allowed', 'first_chromium_request')
        capture(tab, '02-chromium-first')
        # The same Tab survives Chromium -> WebKit -> Chromium; destination
        # request cookies, not a late document.cookie read, prove the barrier.
        script(tab, "await fetch('/?set=chromium'); return true")
        ask(do='ui', zoom=1.35)
        for kind, value, label in [('webKit', 'chromium', 'chromium_to_webkit'),
                                    ('chromium', 'webkit-edited', 'webkit_to_chromium'),
                                    ('webKit', None, 'chromium_signout'),
                                    ('chromium', None, 'webkit_signout')]:
            if label == 'webkit_to_chromium':
                script(tab, "await fetch('/?set=webkit-edited'); return true")
            if label == 'chromium_signout':
                script(tab, "await fetch('/?set=delete'); return true")
            if label == 'webkit_signout':
                # Exercise a WebKit deletion after a WebKit addition too.
                script(tab, "await fetch('/?set=temporary'); return true")
                ask(do='chromium-drm', id=tab, op='cookies')
                script(tab, "await fetch('/?set=delete'); return true")
            script(tab, "localStorage.setItem('switch-local', '" + label + "');sessionStorage.setItem('switch-session','tab-draft');document.querySelector('#draft').value='unfinished';document.querySelector('#secret').value='do-not-transfer';scrollTo(0,220);return true")
            # Alternate the notification decision in the source engine, then
            # read the destination's actual Site Controls facts.
            notify = 'block:' if kind == 'webKit' else 'allow:'
            ask(do='ui', notify=notify + site)
            result = ask(do='chromium-drm', id=tab, op='site-engine', choice=kind)
            checks[label + '_same_tab'] = result['tab'].lower().startswith(tab.lower())
            ready(tab, kind)
            assert_cookies(tab, value, label)
            assert_site_decisions(tab, 'Blocked' if kind == 'webKit' else 'Allowed', label)
            storage = script(tab, "return {boot:window.bootStorage,draft:document.querySelector('#draft').value,secret:document.querySelector('#secret').value}")
            report['states'][label + '_document'] = storage
            checks[label + '_zoom'] = abs(ask(do='site-facts', id=tab)['zoom'] - 1.35) < .004
            checks[label + '_storage_before_scripts'] = storage['boot'] == [label, 'tab-draft']
            checks[label + '_draft'] = storage['draft'] == 'unfinished' and storage['secret'] == ''
            wait_for(lambda: abs(script(tab, 'return scrollY') - 220) < 2, 'Scroll handoff did not land')
            checks[label + '_scroll'] = True
            # A normal reload must retain edits, not replay the old handoff.
            script(tab, "localStorage.setItem('switch-local','after-handoff'); return true")
            before_reload = script(tab, 'return performance.timeOrigin')
            ask(do='chromium-drm', id=tab, op='reload')
            def reloaded():
                try:
                    return script(tab, 'return performance.timeOrigin') != before_reload
                except Exception:
                    return False
            wait_for(reloaded, 'Reload did not commit a new document')
            ready(tab, kind)
            checks[label + '_reload_keeps_edits'] = script(tab, "return localStorage.getItem('switch-local')") == 'after-handoff'
            capture(tab, label)
        checks.update(ask(do='chromium-drm', id=tab, op='cookies')['checks'])
        # Return this host to its global default before testing global
        # restarts. An explicit per-site Chromium override must otherwise win.
        ask(do='chromium-drm', id=tab, op='site-engine', choice='recommended')
        # Establish a synchronized account, then sign out while Chromium is
        # disabled. The persisted ledger must delete its stale Chromium copy.
        script(tab, "await fetch('/?set=before-offline-signout'); return true")
        checks.update(ask(do='chromium-drm', id=tab, op='cookies')['checks'])
        script(tab, "await fetch('/?set=last-chromium-write');return true")
        stop()
        launch('webKit')
        imported = ask(do='usage-open', url=site + '/after-chromium-quit')['id']
        ready(imported, 'webKit')
        assert_cookies(imported, 'last-chromium-write', 'global_chromium_to_webkit_last_write')
        assert_site_decisions(imported, 'Allowed', 'global_chromium_to_webkit_last_write')
        capture(imported, '06-global-webkit-last-write')
        offline = ask(do='usage-open', url=site + '/offline')['id']
        ready(offline, 'webKit')
        script(offline, "await fetch('/?set=delete');return true")
        checks['offline_webkit_signout'] = 'switch_js=' not in script(offline, 'return document.cookie')
        stop()
        launch('chromium')
        resumed = ask(do='usage-open', url=site + '/after-offline-signout')['id']
        ready(resumed, 'chromium')
        assert_cookies(resumed, None, 'restart_preserves_signout')
        assert_site_decisions(resumed, 'Allowed', 'restart_preserves_signout')
        capture(resumed, '07-restart-signed-out')
        # The default engine leaves working pages alone: no reload, same
        # engine, same document, in the tab it moves and in an override's.
        ask(do='chromium-drm', id=resumed, op='site-engine', choice='recommended')
        other_origin = ask(do='usage-open', url=site.replace('127.0.0.1', 'localhost') + '/global-override')['id']
        ready(other_origin, 'chromium')
        ask(do='chromium-drm', id=other_origin, op='site-engine', choice='chromium')
        override_time = script(other_origin, 'return performance.timeOrigin')
        ask(do='select', id=resumed)
        for kind, label in [('webKit', 'global_live_webkit'), ('chromium', 'global_live_chromium')]:
            script(resumed, "await fetch('/?set=" + label + "');localStorage.setItem('switch-local','" + label + "');sessionStorage.setItem('switch-session','global-tab');document.querySelector('#draft').value='global unfinished';return true")
            before = ask(do='tabs')['tabs']
            result = ask(do='chromium-drm', op='global-engine', engine=kind)
            if result.get('error'): raise RuntimeError(result['error'])
            ready(other_origin, 'chromium')
            after = ask(do='tabs')['tabs']
            checks[label + '_rows'] = [r['id'] for r in after] == [r['id'] for r in before]
            checks[label + '_selection'] = [r['id'] for r in after if r['active']] == [resumed]
            checks[label + '_override_document_unchanged'] = script(other_origin, 'return performance.timeOrigin') == override_time
            state = script(resumed, "return {draft:document.querySelector('#draft').value}")
            checks[label + '_draft'] = state['draft'] == 'global unfinished'
            capture(resumed, label)
        # Restore the host policy before the separate certificate scenarios.
        ask(do='chromium-drm', id=other_origin, op='site-engine', choice='recommended')
        # Approve only a self-signed local fixture, then switch engines.
        # No system trust store or keychain setting is changed.
        secured = ask(do='usage-open', url=tls_site + '/')['id']
        wait_for(lambda: ask(do='untrusted', id=secured)['untrusted'], 'Missing fixture certificate screen')
        capture(secured, '08-local-certificate-refused')
        ask(do='untrusted', id=secured, go=True)
        ready(secured, 'chromium')
        for kind in ['webKit', 'chromium']:
            ask(do='chromium-drm', id=secured, op='site-engine', choice=kind)
            ready(secured, kind)
            checks['certificate_chromium_grant_in_' + kind] = not ask(do='untrusted', id=secured)['untrusted']
            capture(secured, '09-certificate-' + kind)
        # A different exact host needs its own decision. Grant it in WebKit
        # and verify Chromium reads that same decision on the return switch.
        other = ask(do='usage-open', url=tls_site.replace('127.0.0.1', 'localhost') + '/')['id']
        wait_for(lambda: ask(do='untrusted', id=other)['untrusted'], 'Other TLS host inherited a grant')
        checks['certificate_other_host_not_trusted'] = True
        ask(do='chromium-drm', id=other, op='site-engine', choice='webKit')
        wait_for(lambda: ask(do='untrusted', id=other)['untrusted'], 'WebKit fixture certificate screen missing')
        ask(do='untrusted', id=other, go=True)
        ready(other, 'webKit')
        ask(do='chromium-drm', id=other, op='site-engine', choice='chromium')
        ready(other, 'chromium')
        checks['certificate_webkit_grant_in_chromium'] = not ask(do='untrusted', id=other)['untrusted']
        capture(other, '10-certificate-webkit-to-chromium')
        # Independent private tabs have separate native contexts. Cookie
        # edits and engine handoff may travel only within the same store.
        private_tabs = []
        for index in range(2):
            private = ask(do='open', url=site + '/private-' + str(index), shy=True, fresh=True)['id']
            private_tabs.append(private)
            ask(do='select', id=private)
            ready(private, 'chromium')
            checks['private_' + str(index) + '_navigation'] = True
            assert_cookies(private, None, 'private_' + str(index) + '_initially_empty')
            if index == 0:
                script(private, "await fetch('/?set=private-one');return true")
            capture(private, '11-private-' + str(index))
        for kind in ['webKit', 'chromium']:
            ask(do='chromium-drm', id=private_tabs[0], op='site-engine', choice=kind)
            ready(private_tabs[0], kind)
            assert_cookies(private_tabs[0], 'private-one', 'private_handoff_' + kind)
        # The host-wide choice applies to the other private tab too, but it
        # must never inherit the first private store's cookie.
        ask(do='chromium-drm', id=private_tabs[1], op='reload')
        ready(private_tabs[1], 'chromium')
        assert_cookies(private_tabs[1], None, 'private_other_store_stays_empty')
        rows = ask(do='tabs')['tabs']
        selected = [row for row in rows if any(row['id'].lower().startswith(tab.lower()) for tab in private_tabs)]
        checks['private_fixture_distinct_webkit_stores'] = (len(selected) == 2 and
            all(row.get('shy') for row in selected) and len({row['store'] for row in selected}) == 2)
        report['states']['private_tabs'] = selected
        report['passed'] = all(checks.values())
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        stop()
        if 'passed' in report:
            report['passed'] = all(checks.values())
        (out / 'summary.json').write_text(json.dumps(report, indent=2))
        subprocess.run(['defaults', 'delete', domain], capture_output=True, timeout=30)
    print(json.dumps(report, indent=2))
    if not report.get('passed'):
        raise RuntimeError('Switch acceptance failed: ' + ', '.join(k for k, v in checks.items() if not v))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    args.out.mkdir(parents=True, exist_ok=True)
    key, cert = args.out / 'fixture-key.pem', args.out / 'fixture-cert.pem'
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, timeout=30,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tls = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    threading.Thread(target=tls.serve_forever, daemon=True).start()
    try:
        run(args.app.resolve(), args.out.resolve(), f'http://127.0.0.1:{server.server_port}', f'https://127.0.0.1:{tls.server_port}')
    finally:
        server.shutdown(); server.server_close()
        tls.shutdown(); tls.server_close()
        key.unlink(missing_ok=True)
