#!/usr/bin/env python3
"""Synthetic site-state round trip, using the real Opens in replacement seam.

No state is injected after a switch until its survival has been measured.
The destination then writes a different value, so the return leg is independent.
Global switching and native profile stores remain the switch owner's contract.
"""
import argparse
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

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'evals'), str(ROOT / 'evals/chromium-scripts')]

# Not here, as docs/chromium-switch.md says: CacheStorage and the back/forward
# stack, which neither a live switch nor EngineStorageCarry takes.
FIELDS = ('cookie', 'httpOnly', 'localStorage', 'sessionStorage', 'indexedDB',
          'form', 'scroll', 'tab', 'tabs', 'url', 'title', 'zoom')

PAGE = b'''<!doctype html><meta charset=utf-8><title>Switch state fixture</title>
<style>body{margin:30px;background:#164b38;color:white;font:22px system-ui;min-height:4000px}
input{font:inherit;position:fixed;top:20px;left:24px;width:360px}
#marker{background:#e0c020;width:200px;height:30px}</style>
<h1>Switch state fixture</h1><div id=marker></div><input id=draft autocomplete=off>
<p>Only synthetic local state. No accounts.</p>
<div style="position:fixed;bottom:16px;right:16px;padding:12px;background:#e0c020;color:#15372d">
Switch state fixture, synthetic local data</div>'''


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.startswith('/auth/'):
            body, mime = b'ok', 'text/plain'
        elif self.path == '/cookies':
            body, mime = json.dumps(self.headers.get('Cookie', '')).encode(), 'application/json'
        else:
            body, mime = PAGE, 'text/html; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        if self.path.startswith('/auth/'):
            self.send_header('Set-Cookie', 'switch_http=' + self.path.rsplit('/', 1)[-1] + '; Path=/; HttpOnly; SameSite=Lax')
        self.end_headers()
        self.wfile.write(body)


DATABASE = '''const db=await new Promise((ok,no)=>{const r=indexedDB.open('parity-switch',1);
r.onupgradeneeded=()=>r.result.createObjectStore('state');r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error)});'''
WRITE = DATABASE + '''
document.cookie='switch_cookie='+VALUE+'; Path=/; SameSite=Lax';
await fetch('/auth/'+VALUE);localStorage.setItem('switch',VALUE);sessionStorage.setItem('switch',VALUE);
await new Promise((ok,no)=>{const t=db.transaction('state','readwrite');t.objectStore('state').put(VALUE,'key');t.oncomplete=ok;t.onerror=()=>no(t.error)});db.close();
const cache=await caches.open('parity-switch');await cache.put('/stored',new Response(VALUE));
document.querySelector('#draft').value=VALUE;history.pushState({},'', '#'+VALUE);scrollTo(0,640);
return true;'''
READ = '''
const db=await new Promise((ok,no)=>{let missing=false;const r=indexedDB.open('parity-switch',1);
r.onupgradeneeded=()=>{missing=true;r.transaction.abort()};
r.onsuccess=()=>ok(r.result);r.onerror=()=>missing?ok(null):no(r.error)});
const indexed=db&&db.objectStoreNames.contains('state')?await new Promise((ok,no)=>{const r=db.transaction('state').objectStore('state').get('key');r.onsuccess=()=>ok(r.result??null);r.onerror=()=>no(r.error)}):null;if(db)db.close();
const cached=await caches.match('/stored',{cacheName:'parity-switch'});
return {cookie:document.cookie,httpOnly:await (await fetch('/cookies')).json(),
localStorage:localStorage.getItem('switch'),sessionStorage:sessionStorage.getItem('switch'),
indexedDB:indexed,cache:cached?await cached.text():null,form:document.querySelector('#draft').value,
scroll:scrollY,history:history.length,url:location.href,title:document.title};'''


def compare(before, after):
    """Compare survival, retaining every field even when another one fails."""
    def normalized(key, value):
        if key in ('cookie', 'httpOnly'):
            return sorted(item.strip() for item in value.split(';') if item.strip())
        return value
    return {key: (abs(before[key] - after[key]) <= 3 if key == 'scroll' else
                  normalized(key, before[key]) == normalized(key, after[key])) for key in FIELDS}


def isolated_space(ask, world):
    """Use a fresh own-sign-ins space, never the signed dev default store."""
    prior = {row['id'] for row in ask(do='spaces')['spaces']}
    name = 'Switch ' + world.rsplit('-', 1)[-1]
    ask(do='space', on=True, new=name, own=True)
    rows = ask(do='spaces')['spaces']
    current = [row for row in rows if row.get('current')]
    if (len(current) != 1 or current[0]['name'] != name or
            current[0]['id'] in prior or current[0].get('own') is not True):
        raise RuntimeError('Fixture requires a fresh space with its own sign-ins')
    # Spaces.store(for:) uses this newly created UUID as its WebKit identifier.
    uuid.UUID(current[0]['id'])
    return current[0]


def run(app, out):
    from launch import launch_exact, require_window
    from ownership import record, cleanup
    from probe_capture import picture
    import yab_socket

    if os.environ.get('YAB_FARM_WORKER') != '1' or os.environ.get('WHERE') not in ('adhd', 'm4', 'renderer-2'):
        raise RuntimeError('Use a signed display farm job off main')
    engine = os.environ.get('YAB_SWITCH_START', 'webKit')
    other = 'chromium' if engine == 'webKit' else 'webKit'
    world = 'parity-switch-' + uuid.uuid4().hex[:12]
    domain = 'dev.serafim.fast.test.' + world
    out.mkdir(parents=True, exist_ok=True)
    defaults = out / 'defaults.plist'
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False,
        'hints.noticing': False, 'searchSuggest': False, 'dev.offer': False,
        'site.engine.127.0.0.1': engine}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True, timeout=15)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:' + str(server.server_port)
    report = dict(initialEngine=engine, route=[engine, other, engine], fields=list(FIELDS), legs=[], pictures=[],
                  scope='Opens in, local fixture; global engine and other profile stores unverified')
    try:
        proc = record(launch_exact(app, dict(os.environ, YAB_ENGINE='chromium', YAB_PROBE=world, YAB_HISTORY='own'), out), out)
        sock = Path(yab_socket.socket_path(world))

        def wait(check, label, seconds=50):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                if proc.poll() is not None:
                    raise RuntimeError('Fixture app exited: ' + label)
                value = check()
                if value:
                    return value
                time.sleep(.15)
            raise TimeoutError(label)

        wait(sock.exists, 'Bench socket missing')
        ask = yab_socket.kwasker(sock, timeout=25, strict=True,
                                fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
        require_window(ask)
        report['spaceIsolation'] = isolated_space(ask, world)
        # Another origin: a page of this one left on the old engine would stop
        # EngineStorageCarry writing there, on purpose, and IndexedDB stays behind.
        sibling = ask(do='usage-open', url=base.replace('127.0.0.1', 'localhost') + '/other')['id']
        tab = ask(do='usage-open', url=base + '/page')['id']
        report['tabs'] = [sibling, tab]

        def ready(expected):
            s = ask(do='chromium-drm', id=tab)
            report['lastState'] = s
            if s.get('failure'):
                raise RuntimeError('Fixture page failed: ' + json.dumps(s))
            return s if s.get('engine') == expected and s.get('title') == 'Switch state fixture' and not s.get('loading') else None

        def js(body):
            return ask(do='chromium-drm', id=tab, op='script', body=body)['value']

        def snapshot():
            value = js(READ)
            value['tab'] = ask(do='chromium-drm', id=tab)['tab']
            value['tabs'] = sorted(t['id'] for t in ask(do='tabs')['tabs'] if not t.get('bench'))
            value['zoom'] = ask(do='site-facts')['zoom']
            return value

        def capture(label):
            ask(do='front')
            ask(do='select', id=tab)
            def attached():
                s = ask(do='chromium-drm', id=tab)
                return s if s['window'] > 0 and (s['engine'] != 'chromium' or s['context'] > 0) else None
            s = wait(attached, 'Selected fixture page has no attached surface')
            path = out / (label + '.png')
            meta = picture(proc.pid, path, window_id=s['window'])
            if meta.get('capture') != 'ScreenCaptureKit':
                raise RuntimeError('ScreenCaptureKit required')
            report['pictures'].append(dict(file=path.name, capture=meta))

        wait(lambda: ready(engine), 'Initial engine not ready')
        ask(do='select', id=tab)
        initial = snapshot()
        report['initialState'] = initial
        if (initial['cookie'] or initial['httpOnly'] or
                any(initial[k] is not None for k in ('localStorage', 'sessionStorage', 'indexedDB', 'cache'))):
            raise RuntimeError('Fresh fixture space already contains site state')
        for index, destination in enumerate((other, engine)):
            token = 'synthetic-' + str(index) + '-' + uuid.uuid4().hex[:8]
            ask(do='ui', zoom=1.25)
            js(WRITE.replace('VALUE', json.dumps(token)))
            before = snapshot()
            # Refuse vacuous survival checks if fixture writes never took effect.
            if any(before[k] != token for k in ('localStorage', 'sessionStorage', 'indexedDB', 'cache', 'form')):
                raise RuntimeError('Fixture state write did not complete')
            if ('switch_cookie=' + token not in before['cookie'] or
                    'switch_http=' + token not in before['httpOnly'] or
                    before['scroll'] < 500 or abs(before['zoom'] - 1.25) > .01 or
                    len(before['tabs']) < 2):
                raise RuntimeError('Fixture cookie, scroll, zoom or sibling tab precondition failed')
            capture(f'{index}-before')
            ask(do='chromium-drm', id=tab, op='site-engine', choice=destination)
            wait(lambda: ready(destination), 'Destination engine not ready')
            after = snapshot()
            checks = compare(before, after)
            report['legs'].append(dict(destination=destination, before=before, after=after, checks=checks))
            capture(f'{index}-after')
        report['passed'] = len(report['legs']) == 2 and all(all(leg['checks'].values()) for leg in report['legs'])
    except Exception as error:
        report.update(passed=False, error=repr(error))
    finally:
        (out / 'switch-state.json').write_text(json.dumps(report, indent=2) + '\n')
        cleanup(out)
        server.shutdown()
        server.server_close()
        subprocess.run(['defaults', 'delete', domain], capture_output=True, timeout=15)
    print(json.dumps(report), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    raise SystemExit(run(a.app.resolve(), a.out.resolve()))
