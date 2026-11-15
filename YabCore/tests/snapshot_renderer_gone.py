#!/usr/bin/env python3
"""A page picture in flight when its renderer goes.

Crash reports 1084, 1103, 1353, 1552: YabCore's main thread, null dereference
in RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived (the retry's
GetView()->CopyFromSurface) under DelegatedFrameHost's copy callback. YabCore's
page.snapshot is CDP Page.captureScreenshot (from the surface). When the
renderer dies with the copy in flight (Yab ending a page that stopped
answering, YabCore shedding a hidden tab, an out-of-memory kill), the view is
gone, the copy comes back empty, and Chromium retries on the null view.
CEF patch 0106 returns the empty picture instead.

Usage: snapshot_renderer_gone.py YABCORE_EXECUTABLE [--rounds N]
Exit 0: YabCore survived every round. Exit 1: it crashed (reproduced).
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run import wait_socket

PAGE = (b'<!doctype html><title>Picture</title><body style="margin:0;background:#2a6">'
        b'<canvas id=c width=800 height=600></canvas><script>'
        b'const c=document.getElementById("c").getContext("2d");let n=0;'
        b'(function f(){c.fillStyle="hsl("+(n++%360)+",70%,50%)";c.fillRect(0,0,800,600);requestAnimationFrame(f)})()'
        b'</script>')


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('helper', type=Path)
    parser.add_argument('--rounds', type=int, default=60)
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT']) / 'snapshot-renderer-gone'
    out.mkdir(parents=True, exist_ok=True)
    report = {'rounds': [], 'machine': os.uname().nodename, 'helper': str(args.helper)}
    started = time.time()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    helper = peer = None
    code = 2
    seq = 0
    replies = {}
    events = []
    try:
        with tempfile.TemporaryDirectory(prefix='ycs-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            helper = subprocess.Popen([str(args.helper), f'--socket={endpoint}', f'--data-root={directory / "data"}',
                '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'],
                stdout=log, stderr=log, start_new_session=True)
            wait_socket(endpoint, helper)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(20)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')

            def send(method, params=None):
                nonlocal seq
                seq += 1
                ident = str(seq)
                peer.sendall((json.dumps({'v': 1, 'id': ident, 'method': method, 'params': params or {}}) + '\n').encode())
                return ident

            def wait(ident):
                while ident not in replies:
                    line = reader.readline()
                    if not line:
                        raise ConnectionError('YabCore disconnected')
                    message = json.loads(line)
                    if 'event' in message:
                        events.append(message['event'])
                    else:
                        replies[message.get('id')] = message
                return replies.pop(ident)

            def request(method, params=None):
                message = wait(send(method, params))
                if 'error' in message:
                    raise RuntimeError(method + ': ' + json.dumps(message['error']))
                return message['result']

            def ready(tab, timeout=30):
                end = time.monotonic() + timeout
                while time.monotonic() < end:
                    state = request('tab.state', {'tab': tab})
                    if state.get('devToolsReady') and state.get('rendererPID') and state.get('hasDocument') and not state.get('loading'):
                        return state
                    time.sleep(.1)
                raise RuntimeError('page not ready: ' + json.dumps(state)[:600])

            request('hello')
            request('profile.open', {'profile': 'pictures'})
            tab = request('tab.create', {'profile': 'pictures', 'url': base + '/'})['tab']
            ready(tab)
            pictures = request('page.snapshot', {'tab': tab})
            report['firstPicture'] = len((pictures or {}).get('data', ''))
            for round_ in range(args.rounds):
                delay = (round_ % 30) * 0.002
                state = ready(tab)
                picture = send('page.snapshot', {'tab': tab})
                time.sleep(delay)
                kill = send('page.killRenderer', {'tab': tab, 'rendererPID': state['rendererPID']})
                row = {'round': round_, 'delayMs': round(delay * 1000), 'renderer': state['rendererPID']}
                try:
                    row['picture'] = (lambda m: m.get('error') or len((m.get('result') or {}).get('data', '')))(wait(picture))
                    row['kill'] = wait(kill).get('error', 'ok')
                except ConnectionError as error:
                    row['disconnect'] = repr(error)
                    report['rounds'].append(row)
                    break
                report['rounds'].append(row)
                request('tab.reload', {'tab': tab})
            time.sleep(1)
            report['helperExit'] = helper.poll()
            survived = report['helperExit'] is None and not any('disconnect' in r for r in report['rounds'])
            report['survived'] = survived
            if survived:
                request('shutdown')
                helper.wait(timeout=20)
                code = 0
            else:
                code = 1
    except Exception as error:
        report['error'] = repr(error) + ' ' + traceback.format_exc()[-1500:]
        if helper and helper.poll() is not None:
            report['helperExit'] = helper.poll()
            code = 1
    finally:
        if peer:
            peer.close()
        if helper and helper.poll() is None:
            try:
                os.killpg(helper.pid, signal.SIGTERM)
                helper.wait(timeout=10)
            except Exception:
                pass
        server.shutdown()
        server.server_close()
        time.sleep(3)  # ReportCrash writes the .ips shortly after the exit.
        folder = Path.home() / 'Library/Logs/DiagnosticReports'
        reports = []
        for path in folder.glob('YabCore*.ips'):
            # Only this run's helper: other jobs' YabCore copies crash on the same Mac.
            text = path.read_text(errors='replace') if path.stat().st_mtime >= started else ''
            if text and helper and json.loads(text[text.index('\n{') + 1:]).get('pid') == helper.pid:
                reports.append(str(path))
        report['crashReports'] = reports
        report['exitCode'] = code
        for path in reports:
            shutil.copy(path, out / Path(path).name)
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: report.get(k) for k in ('survived', 'helperExit', 'firstPicture', 'crashReports', 'error', 'exitCode')}, indent=2))
        print('rounds', json.dumps(report['rounds'][-6:]), flush=True)
        for path in reports:
            text = Path(path).read_text(errors='replace')
            body = json.loads(text[text.index('\n{') + 1:])
            thread = body['threads'][body.get('faultingThread', 0)]
            names = {i: image.get('name') for i, image in enumerate(body.get('usedImages', []))}
            print('crash', body.get('exception'), flush=True)
            for frame in thread['frames'][:8]:
                print('  ', names.get(frame.get('imageIndex')), hex(frame.get('imageOffset', 0)), frame.get('symbol', ''), flush=True)
    sys.exit(code)


if __name__ == '__main__':
    main()
