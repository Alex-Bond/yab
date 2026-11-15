#!/usr/bin/env python3
"""A permission element (<geolocation>, <usermedia>) clicked and every
question answered yes, as Yab answers a site it remembers.

Reports 623, 1019, 1108, 1291, 1357, 1448, 1449, 1487, 1499, 1502-1504, 1550:
CHECK in PermissionRequest::PermissionGranted/PermissionDenied (a null
permission_decided_callback_) < PermissionRequestManager::Accept/Deny <
CefPermissionPrompt::NotifyDelegate < YabCore's answer to a native question.

A request the page's permission element starts runs Chromium's embedded
prompt flow. After the user allows it, PermissionRequestManager keeps the
same, already decided requests and recreates the prompt for the next
variant when macOS has not granted the app that permission (kOsPrompt,
kOsSystemSettings). CEF's prompt forwards that as a second
OnShowPermissionPrompt; an Allow or Deny to it decides the requests again.
YabCore/cef-patches/0101 keeps those system steps from the client; YabCore
closes one raised inside its own answer (questions.inc, AskPermission).

  permission_element.py HELPER --element geolocation|usermedia --expect crash|clean

Writes $YAB_FARM_OUT/<element>-<expect>.json: the questions YabCore opened,
how the helper ended and the crash report's first frames.
"""
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

assert os.environ.get('YAB_FARM_WORKER') == '1', 'Run through ./farm'
helper = Path(sys.argv[1])
args = sys.argv[2:]
element = args[args.index('--element') + 1]
expect = args[args.index('--expect') + 1]
assert element in ('geolocation', 'usermedia'), element
assert expect in ('crash', 'clean'), expect
out = Path(os.environ['YAB_FARM_OUT'])
mode = element + '-' + expect
reports = Path.home() / 'Library/Logs/DiagnosticReports'
before = {p.name for p in reports.glob('YabCore*')} if reports.exists() else set()

PAGE = ('<!doctype html><title>Permission element</title>'
        '<style>body{margin:0;font:20px system-ui}#el{position:absolute;left:60px;top:60px}</style>'
        '<' + element + ' id="el"></' + element + '>'
        '<script>window.events=[];for(const n of ["promptaction","promptdismiss","validationstatuschange","location","stream"])'
        'el.addEventListener(n,()=>events.push(n));</script>').encode()


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
site = 'http://127.0.0.1:%d/' % server.server_port

questions, steps = [], []
code, error = None, None
with tempfile.TemporaryDirectory(prefix='yc-perm-', dir='/tmp') as temporary:
    endpoint = Path(temporary) / 'core.sock'
    with (out / (mode + '-helper.log')).open('w') as log:
        process = subprocess.Popen([str(helper), '--socket=' + str(endpoint),
            '--data-root=' + temporary + '/data', '--use-mock-keychain', '--no-sandbox'],
            stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while not endpoint.exists():
                assert process.poll() is None and time.monotonic() < deadline, 'Helper did not start'
                time.sleep(.1)
            sock = socket.socket(socket.AF_UNIX)
            sock.connect(str(endpoint)); sock.settimeout(30)
            stream = sock.makefile('rb')
            serial = [0]

            def send(method, **params):
                serial[0] += 1
                request = str(serial[0])
                sock.sendall((json.dumps(dict(v=1, id=request, method=method, params=params)) + '\n').encode())
                return request

            def read():
                raw = stream.readline()
                if not raw:
                    raise EOFError('helper connection ended')
                value = json.loads(raw)
                if value.get('event') == 'question.open':
                    p = value['params']
                    questions.append(dict(at=round(time.monotonic(), 3), kind=p.get('kind'),
                                          camera=p.get('camera'), microphone=p.get('microphone')))
                    # Yes to every question, kept: what Yab does for a site
                    # it remembers, and what a user clicking Allow does.
                    send('question.reply', tab=p['tab'], request=p['request'], allow=True, keep=True)
                return value

            def call(method, **params):
                request = send(method, **params)
                while True:
                    value = read()
                    if value.get('id') == request:
                        assert 'error' not in value, (method, value)
                        return value.get('result')

            def js(function):
                return call('script.evaluate', tab=tab, world='perm-test', function=function)

            call('hello'); call('profile.open', profile='perm', private=True)
            tab = call('tab.create', profile='perm', url=site)['tab']
            call('tab.resize', tab=tab, width=800, height=600, scale=1)
            call('tab.visible', tab=tab, visible=True)
            deadline = time.monotonic() + 20
            while not call('tab.state', tab=tab).get('devToolsReady'):
                assert time.monotonic() < deadline, 'Page never became scriptable'
                time.sleep(.1)
            deadline, seen = time.monotonic() + 25, None
            while True:
                state = js('function(){const e=document.getElementById("el");'
                           'if(!e)return {defined:null,url:location.href,ready:document.readyState};'
                           'const r=e.getBoundingClientRect();'
                           'return {defined:e.constructor.name,valid:e.isValid,reason:e.invalidReason,'
                           'status:e.permissionStatus,visibility:document.visibilityState,'
                           'x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height}}')
                steps.append(dict(step='element', **state))
                # <usermedia> keeps isValid behind its origin trial: give it
                # the element's own 500 ms settle time, four times over.
                if state.get('defined') and 'valid' not in state:
                    seen = seen or time.monotonic()
                    if time.monotonic() - seen >= 2:
                        break
                if state.get('valid') or time.monotonic() >= deadline:
                    break
                time.sleep(.5)
            assert state.get('valid') or (seen and 'valid' not in state), \
                ('Permission element never became valid', state)
            for kind in ('mouseMove', 'mouseDown', 'mouseUp'):
                call('input.send', tab=tab, kind=kind, x=state['x'], y=state['y'], clickCount=1)
            # Every question answered as it comes; follow-ups are opened from
            # inside the previous answer, so a few seconds hold all of them.
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    call('tab.state', tab=tab)
                except (EOFError, OSError, socket.timeout) as e:
                    error = repr(e); break
                time.sleep(.3)
            if error is None:
                steps.append(dict(step='after', **js('function(){const e=document.getElementById("el");'
                    'return {status:e.permissionStatus,events:window.events}}')))
                stream.close(); sock.shutdown(socket.SHUT_RDWR); sock.close()
            code = process.wait(timeout=40)
        except (EOFError, OSError, socket.timeout) as e:
            error = repr(e)
            code = process.wait(timeout=40)
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
    server.shutdown()
    time.sleep(5)  # ReportCrash writes the report a moment after the exit
    new = sorted(p for p in reports.glob('YabCore*') if p.name not in before) if reports.exists() else []
    frames, fault = [], None
    for report in new[:1]:
        text = report.read_text(errors='replace')
        _, _, body = text.partition('\n')
        try:
            ips = json.loads(body)
            thread = ips['threads'][ips.get('faultingThread', 0)]
            images = ips['usedImages']
            frames = [dict(image=images[f['imageIndex']].get('name'), offset=f.get('imageOffset'),
                           symbol=f.get('symbol')) for f in thread['frames'][:30]]
            fault = ips.get('exception')
        except (ValueError, KeyError, IndexError):
            pass
    result = dict(mode=mode, exit=code, signal=-code if code is not None and code < 0 else None,
                  questions=questions, steps=steps, error=error,
                  reports=[p.name for p in new], fault=fault, frames=frames)
    (out / (mode + '.json')).write_text(json.dumps(result, indent=2))
    print(json.dumps(result)[:4000], flush=True)
    if expect == 'crash':
        assert code == -signal.SIGTRAP, ('Expected the permission CHECK (SIGTRAP)', code)
        assert len(questions) >= 2, ('Expected a second question for the decided request', questions)
        print('PASS: %s: second question for the decided request, helper trapped' % mode, flush=True)
    else:
        assert code == 0 and not new, ('Expected a clean exit', code, [p.name for p in new])
        # The one site question; the system step after it never reaches Yab.
        assert len(questions) == 1, ('Expected exactly one question', questions)
        log = (out / (mode + '-helper.log')).read_text(errors='replace')
        closed = 'system step' in log
        print('%s: system step after the Allow %s' % (mode, 'closed by YabCore' if closed else
              'not raised (macOS already granted this permission, or CEF 0101 handled it)'), flush=True)
        print('PASS: %s: %d question(s), helper exited cleanly' % (mode, len(questions)), flush=True)
