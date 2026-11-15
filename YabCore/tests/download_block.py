#!/usr/bin/env python3
"""Does a refusal YabCore makes on its own keep a site's automatic downloads
blocked? (Follow-up of #1940.)

Chromium asks "download multiple files" (DownloadRequestLimiter) on a page's
second file. YabCore answers that prompt itself: Allow for a tab Yab shows
(Yab's own card then decides each file), and a refusal for a tab nobody can
be asked for: one Yab hasn't adopted, one closing, a task read page, an
internal one. Chromium takes a Deny as the person's Block and keeps it as the
site's AUTOMATIC_DOWNLOADS = BLOCK (TabDownloadState::Cancel), and an Allow
as ALLOW (Accept). Only a dismissal keeps nothing (CancelOnce).

A popup no client adopts (this probe adopts none) is such a tab. Here:

  A  on localhost: a click opens a popup that sends four files at once;
     what Chromium then holds for localhost.
  B  the same tab, reloaded as a normal tab: one click, four files a few
     hundred ms apart; how many reach OnBeforeDownload (download.open).
  C  on 127.0.0.1, never refused: the same four files, and what Chromium
     holds after YabCore's own Allow.
  D  the helper restarted on the same data: B again, and what is kept.
  E  (fixed only) a block left in the profile by an older YabCore, written
     with permission.set: gone after the next start, all four through.

  download_block.py HELPER --expect bug|fixed

bug: A holds BLOCK, B and D let one file of four through, C holds ALLOW.
fixed: nothing is held anywhere, B to E let all four through to Yab.
Writes $YAB_FARM_OUT/download-block-<expect>.json.
"""
import http.server
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

assert os.environ.get('YAB_FARM_WORKER') == '1', 'Run through ./farm'
helper = Path(sys.argv[1])
args = sys.argv[2:]
expect = args[args.index('--expect') + 1]
assert expect in ('bug', 'fixed'), expect
out = Path(os.environ['YAB_FARM_OUT'])
SIZE = 50_000
VALUES = {0: 'default', 1: 'allow', 2: 'block', 3: 'ask'}

BUTTON = ('<button id=go style="position:absolute;left:40px;top:40px;width:320px;height:90px;font-size:24px">Go</button>')
PAGES = {
    # A click opens a window; the window sends four files at once, as a
    # download page opened in its own window does.
    '/opener': BUTTON + '<script>go.onclick=()=>{window.open("/burst?tag="+new URLSearchParams(location.search).get("tag"),'
               '"_blank","popup,width=420,height=320")}</script>',
    '/burst': '<p>burst</p><script>const tag=new URLSearchParams(location.search).get("tag");'
              'for(let n=1;n<=4;n++){const f=document.createElement("iframe");f.style.display="none";'
              'f.src="/blob/"+tag+"-part-"+n+".bin";document.body.appendChild(f)}</script>',
    # One click, four parts a few hundred ms apart (evals/download-parts).
    '/parts': BUTTON + '<script>window.started=[];go.onclick=()=>{const tag=new URLSearchParams(location.search).get("tag");'
              '[0,300,600,900].forEach((ms,i)=>setTimeout(()=>{const f=document.createElement("iframe");f.style.display="none";'
              'f.src="/blob/"+tag+"-part-"+(i+1)+".bin";document.body.appendChild(f);window.started.push(i+1)},ms))}</script>',
}
hits = []


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith('/blob/'):
            hits.append(path)
            body = b'x' * SIZE
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="%s"' % path.rsplit('/', 1)[1])
        else:
            body = ('<!doctype html><meta charset=utf-8><title>%s</title>' % path + PAGES.get(path, '')).encode()
            self.send_response(200 if path in PAGES else 404)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
PORT = server.server_port
REFUSED, CONTROL = 'http://localhost:%d' % PORT, 'http://127.0.0.1:%d' % PORT


class Core:
    """One YabCore helper on a data root, spoken to as Yab speaks to it."""

    def __init__(self, data, log, folder):
        self.endpoint = Path(tempfile.mkdtemp(prefix='yc-dl-', dir='/tmp')) / 'core.sock'
        self.process = subprocess.Popen([str(helper), '--socket=' + str(self.endpoint), '--data-root=' + str(data),
                                         '--use-mock-keychain', '--no-sandbox'], stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while not self.endpoint.exists():
            assert self.process.poll() is None and time.monotonic() < deadline, 'Helper did not start'
            time.sleep(.1)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(str(self.endpoint))
        self.buffer, self.serial, self.folder = b'', 0, folder
        self.opened, self.questions, self.created = [], [], []

    def send(self, method, **params):
        self.serial += 1
        request = str(self.serial)
        self.sock.sendall((json.dumps(dict(v=1, id=request, method=method, params=params)) + '\n').encode())
        return request

    def line(self, until):
        while b'\n' not in self.buffer:
            left = until - time.monotonic()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.sock], [], [], left)
            if not ready:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError('helper connection ended')
            self.buffer += chunk
        raw, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(raw)

    def handle(self, value):
        name, p = value.get('event'), value.get('params') or {}
        if name == 'download.open':
            self.opened.append(dict(tab=p.get('tab'), url=p.get('url'), name=p.get('name')))
            # Saved, as Yab saves a file it lets in.
            self.send('download.destination', tab=p['tab'], download=p['download'],
                      path=str(self.folder / ('%d-%s' % (len(self.opened), p.get('name') or 'file'))))
        elif name == 'question.open':
            self.questions.append(dict(kind=p.get('kind'), tab=p.get('tab'), origin=p.get('origin')))
            self.send('question.reply', tab=p['tab'], request=p['request'], allow=False, keep=False)
        elif name == 'tab.created':
            self.created.append(dict(tab=p.get('tab'), opener=p.get('opener'), url=p.get('url')))

    def call(self, method, **params):
        request = self.send(method, **params)
        until = time.monotonic() + 30
        while True:
            value = self.line(until)
            assert value is not None, ('No reply', method)
            if value.get('id') == request:
                assert 'error' not in value, (method, value)
                return value.get('result')
            self.handle(value)

    def pump(self, seconds):
        until = time.monotonic() + seconds
        while True:
            value = self.line(until)
            if value is None:
                return
            self.handle(value)

    def js(self, tab, function):
        return self.call('script.evaluate', tab=tab, world='download-block', function=function)

    def page(self, url):
        tab = self.call('tab.create', profile='dl', url=url)['tab']
        self.call('tab.resize', tab=tab, width=800, height=600, scale=1)
        self.call('tab.visible', tab=tab, visible=True)
        self.ready(tab, url)
        return tab

    def ready(self, tab, url):
        deadline = time.monotonic() + 20
        while True:
            state = self.call('tab.state', tab=tab)
            if state.get('devToolsReady'):
                try:
                    here = self.js(tab, 'function(){return [location.href, document.readyState, !!document.getElementById("go")]}')
                    if here[0] == url and here[1] == 'complete' and here[2]:
                        return
                except AssertionError:
                    pass
            assert time.monotonic() < deadline, ('Page never became ready', url)
            self.pump(.2)

    def click(self, tab):
        for kind in ('mouseMove', 'mouseDown', 'mouseUp'):
            self.call('input.send', tab=tab, kind=kind, x=200, y=85, clickCount=1)

    def held(self, tab, origin):
        values = self.call('permission.state', tab=tab, origin=origin)['values']['automatic-downloads']
        return VALUES.get(values['origin'], values['origin'])

    def files(self, tag):
        return sorted(o['name'] for o in self.opened if tag in (o.get('url') or ''))

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        try:
            return self.process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return self.process.wait()


result = dict(expect=expect, port=PORT)
with tempfile.TemporaryDirectory(prefix='yc-dl-data-', dir='/tmp') as temporary:
    data, folder = Path(temporary) / 'data', Path(temporary) / 'files'
    folder.mkdir()
    with (out / ('download-block-%s-helper.log' % expect)).open('w') as log:
        core = Core(data, log, folder)
        core.call('hello')
        core.call('profile.open', profile='dl', private=False)

        # A: refused by YabCore in a window nobody adopted.
        tab = core.page(REFUSED + '/opener?tag=a')
        core.click(tab)
        # Until the window's files have been asked for, and a moment after.
        until = time.monotonic() + 20
        while time.monotonic() < until and len([h for h in hits if '/a-part-' in h]) < 4:
            core.pump(.5)
        core.pump(3)
        result['A'] = dict(popups=core.created, requested=sorted(h for h in hits if '/a-part-' in h),
                           to_yab=core.files('a-part-'), held=core.held(tab, REFUSED))
        print('A', json.dumps(result['A']), flush=True)

        # B: the same site in a normal tab, reloaded by the browser.
        url = REFUSED + '/parts?tag=b'
        core.call('tab.navigate', tab=tab, url=url)
        core.ready(tab, url)
        core.click(tab)
        core.pump(5)
        result['B'] = dict(started=core.js(tab, 'function(){return window.started}'),
                           a_requested_by_now=sorted(h for h in hits if '/a-part-' in h),
                           requested=sorted(h for h in hits if '/b-part-' in h), to_yab=core.files('b-part-'),
                           held=core.held(tab, REFUSED))
        print('B', json.dumps(result['B']), flush=True)

        # C: a site never refused, its second file let through by YabCore.
        other = core.page(CONTROL + '/parts?tag=c')
        core.click(other)
        core.pump(5)
        result['C'] = dict(requested=sorted(h for h in hits if '/c-part-' in h), to_yab=core.files('c-part-'),
                           held=core.held(other, CONTROL))
        print('C', json.dumps(result['C']), flush=True)
        result['first_exit'] = core.close()
        result['questions'] = core.questions

        # D: the same data after a restart: is the block kept?
        core = Core(data, log, folder)
        core.call('hello')
        core.call('profile.open', profile='dl', private=False)
        tab = core.page(REFUSED + '/parts?tag=d')
        held = core.held(tab, REFUSED)
        core.click(tab)
        core.pump(5)
        result['D'] = dict(held_at_start=held, requested=sorted(h for h in hits if '/d-part-' in h),
                           to_yab=core.files('d-part-'), held=core.held(tab, REFUSED),
                           control_held=core.held(tab, CONTROL))
        print('D', json.dumps(result['D']), flush=True)
        if expect == 'fixed':
            # E: a block an older YabCore left in the profile goes with the
            # next start (Preferences seeding); Yab writes its own again.
            core.call('permission.set', profile='dl', entries=[dict(origin=REFUSED, kind='automatic-downloads', value='block')])
            core.pump(.5)
            seeded = core.held(tab, REFUSED)
            result['second_exit'] = core.close()
            result['questions'] += core.questions
            core = Core(data, log, folder)
            core.call('hello')
            core.call('profile.open', profile='dl', private=False)
            tab = core.page(REFUSED + '/parts?tag=e')
            held = core.held(tab, REFUSED)
            core.click(tab)
            core.pump(5)
            result['E'] = dict(seeded=seeded, held_at_start=held, to_yab=core.files('e-part-'))
            print('E', json.dumps(result['E']), flush=True)
        result['last_exit'] = core.close()
        result['questions'] += core.questions
server.shutdown()
(out / ('download-block-%s.json' % expect)).write_text(json.dumps(result, indent=1))

A, B, C, D = (result[k] for k in 'ABCD')
checks = []
if expect == 'bug':
    checks += [('A: the refusal kept a block', A['held'] == 'block'),
               ('B: one file of four reached Yab, the rest dropped unasked', len(B['to_yab']) == 1),
               ('C: YabCore\'s own Allow kept an allow', C['held'] == 'allow'),
               ('D: the block outlived the restart', D['held_at_start'] == 'block' and len(D['to_yab']) == 1)]
else:
    checks += [('A: nothing kept by the refusal', A['held'] in ('ask', 'default')),
               ('B: all four files reached Yab', len(B['to_yab']) == 4),
               ('C: all four, and nothing kept by YabCore\'s own Allow', len(C['to_yab']) == 4 and C['held'] in ('ask', 'default')),
               ('D: nothing kept after the restart, all four reached Yab',
                D['held_at_start'] in ('ask', 'default') and len(D['to_yab']) == 4 and D['control_held'] in ('ask', 'default')),
               ('E: a block left from before is gone at the next start',
                result['E']['seeded'] == 'block' and result['E']['held_at_start'] in ('ask', 'default') and len(result['E']['to_yab']) == 4)]
for name, ok in checks:
    print('%s %s' % ('PASS' if ok else 'FAIL', name), flush=True)
sys.exit(0 if all(ok for _, ok in checks) else 1)
