#!/usr/bin/env python3
"""Save to Drive in Chrome's PDF viewer.

Crash report 1524 (0.46.2x helper, CEF 4c4c440e): YabCore's main thread,
EXC_BREAKPOINT, CHECK(add_account_popup_) in
save_to_drive::AccountChooserController::ResizeAndFocusAddAccountPopup <- Show
<- GetAccount <- SaveToDriveFlow::Run <- PdfViewerPrivateSaveToDriveFunction.
With no Google account in the profile (Yab never signs Chrome in) the flow
opens Chrome's sign-in as a NEW_POPUP through OpenURLFromTab; YabCore's
OnOpenURLFromTab hands every such open to Yab as page.openLink, CEF returns no
WebContents, and the CHECK fails. CEF patch 0108 cancels the upload instead.

The probe sends what the viewer's Save to Drive button sends
(chrome.pdfViewerPrivate.saveToDrive('ORIGINAL')) from the viewer's own frame,
and records whether the viewer offers the button (pdfSaveToDrive).

Usage: pdf_save_to_drive.py YABCORE_EXECUTABLE
Exit 0: no button to press (YabCore starts with PdfSaveToDrive off), or
YabCore survived the press. Exit 1: it ended (reproduced). Exit 2: inconclusive.
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

PDF_VIEWER = 'mhjfbmdgcfjbbpaeojofohoefgiehjai'


def tiny_pdf():
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
               None, b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    stream = b'BT /F1 24 Tf 40 100 Td (Save to Drive) Tj ET'
    objects[3] = b'<< /Length %d >>\nstream\n' % len(stream) + stream + b'\nendstream'
    out, offsets = b'%PDF-1.4\n', []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b'%d 0 obj\n' % i + body + b'\nendobj\n'
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objects) + 1)
    out += b''.join(b'%010d 00000 n \n' % o for o in offsets)
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objects) + 1, xref)
    return out


PDF = tiny_pdf()


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/pdf')
        self.send_header('Content-Length', str(len(PDF)))
        self.end_headers()
        self.wfile.write(PDF)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('helper', type=Path)
    args = parser.parse_args()
    out = Path(os.environ['YAB_FARM_OUT']) / 'pdf-save-to-drive'
    out.mkdir(parents=True, exist_ok=True)
    report = {'machine': os.uname().nodename, 'helper': str(args.helper)}
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    helper = peer = None
    code = 2
    seq = 0
    try:
        with tempfile.TemporaryDirectory(prefix='ycp-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            endpoint = directory / 'core.sock'
            helper = subprocess.Popen([str(args.helper), f'--socket={endpoint}', f'--data-root={directory / "data"}',
                '--no-sandbox', '--use-mock-keychain', '--no-default-browser-check'],
                stdout=log, stderr=log, start_new_session=True)
            report['pid'] = helper.pid
            wait_socket(endpoint, helper)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(30)
            peer.connect(str(endpoint))
            reader = peer.makefile('rb')

            def request(method, params=None, allow_error=False):
                nonlocal seq
                seq += 1
                ident = str(seq)
                peer.sendall((json.dumps({'v': 1, 'id': ident, 'method': method, 'params': params or {}}) + '\n').encode())
                while True:
                    line = reader.readline()
                    if not line:
                        raise ConnectionError('YabCore disconnected during ' + method)
                    message = json.loads(line)
                    if 'event' in message:
                        continue
                    if message.get('id') != ident:
                        continue
                    if 'error' in message:
                        if allow_error:
                            return {'error': message['error']}
                        raise RuntimeError(method + ': ' + json.dumps(message['error']))
                    return message['result']

            request('hello')
            request('profile.open', {'profile': 'pdf'})
            tab = request('tab.create', {'profile': 'pdf', 'url': base + '/file.pdf'})['tab']
            viewer = None
            end = time.monotonic() + 40
            while time.monotonic() < end and not viewer:
                contexts = request('scripts.status', {'tab': tab}, allow_error=True).get('contexts', [])
                viewer = next((c for c in contexts if c.get('default') and c.get('host') == PDF_VIEWER), None)
                time.sleep(.3)
            report['contexts'] = [{k: c.get(k) for k in ('url', 'scheme', 'host', 'default', 'session')} for c in contexts]
            if not viewer:
                raise RuntimeError('PDF viewer context not found')

            def viewer_js(body):
                return request('scripts.evaluate', {'tab': tab, 'frame': viewer['token'], 'world': '',
                               'function': 'async function(){' + body + '}'}, allow_error=True)

            strings = viewer_js("return await new Promise(r=>chrome.resourcesPrivate.getStrings('pdf', s=>r({drive: Object.fromEntries(Object.entries(s || {}).filter(([k])=>/drive/i.test(k))), incognito: chrome.extension.inIncognitoContext})))")
            report['strings'] = strings
            report['saveToDriveOffered'] = json.dumps(strings).find('"pdfSaveToDrive": true') >= 0
            if not report['saveToDriveOffered'] and not os.environ.get('YAB_PRESS_ANYWAY'):
                # No button, nothing a person can press. YAB_PRESS_ANYWAY=1
                # sends it anyway, to check cef-patches/0108 on a new SDK.
                request('shutdown', allow_error=True)
                helper.wait(timeout=20)
                code = 0
                return
            # What the viewer's Save to Drive button sends.
            try:
                report['saveToDrive'] = viewer_js("return await new Promise(r=>chrome.pdfViewerPrivate.saveToDrive('ORIGINAL', ()=>r(chrome.runtime.lastError ? chrome.runtime.lastError.message : 'ok')))")
                time.sleep(3)
                report['after'] = request('tab.state', {'tab': tab}, allow_error=True)
            except (ConnectionError, OSError) as error:
                report['disconnect'] = repr(error)
            time.sleep(1)
            report['helperExit'] = helper.poll()
            if report['helperExit'] is None and 'disconnect' not in report:
                request('shutdown', allow_error=True)
                helper.wait(timeout=20)
                code = 0
            else:
                code = 1
    except Exception as error:
        report['error'] = repr(error) + ' ' + traceback.format_exc()[-1500:]
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
        time.sleep(10)  # ReportCrash writes the .ips shortly after the exit.
        reports = []
        for path in (Path.home() / 'Library/Logs/DiagnosticReports').glob('YabCore*.ips'):
            text = path.read_text(errors='replace')
            # Only this run's helper: other jobs' YabCore copies crash on the same Mac.
            if helper and json.loads(text[text.index('\n{') + 1:]).get('pid') == helper.pid:
                reports.append(path)
                shutil.copy(path, out / path.name)
        report['crashReports'] = [str(p) for p in reports]
        report['exitCode'] = code
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: report.get(k) for k in ('saveToDriveOffered', 'strings', 'saveToDrive', 'helperExit',
                                                      'disconnect', 'crashReports', 'error', 'exitCode')}, indent=2), flush=True)
        for path in reports:
            text = path.read_text(errors='replace')
            body = json.loads(text[text.index('\n{') + 1:])
            thread = body['threads'][body.get('faultingThread', 0)]
            names = {i: image.get('name') for i, image in enumerate(body.get('usedImages', []))}
            print('crash', body.get('exception'), flush=True)
            for frame in thread['frames'][:10]:
                print('  ', names.get(frame.get('imageIndex')), hex(frame.get('imageOffset', 0)), frame.get('symbol', ''), flush=True)
    sys.exit(code)


if __name__ == '__main__':
    main()
