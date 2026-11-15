#!/usr/bin/env python3
"""Native JS continuation and first-navigation proof on the exact signed helper."""
import argparse
import http.server
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import time
import traceback


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Native dialog fixture</title><h1>Native dialog fixture</h1>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(app, out):
    if os.environ.get('WHERE') not in ('adhd', 'm4', 'renderer-2'):
        raise RuntimeError('Native dialog proof requires a permitted farm worker')
    out.mkdir(parents=True, exist_ok=True)
    summary = {'checks': [], 'passed': False, 'helper': str(app / 'Contents/MacOS/YabCore')}
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    child = peer = None
    messages, buffer, serial = [], b'', 0

    def check(label, condition):
        summary['checks'].append({'name': label, 'passed': bool(condition)})
        print(('PASS ' if condition else 'FAIL ') + label, flush=True)
        assert condition, label

    def take(predicate, seconds=20):
        nonlocal buffer
        deadline = time.monotonic() + seconds
        while True:
            for index, message in enumerate(messages):
                if predicate(message):
                    return messages.pop(index)
            if child.poll() is not None:
                raise RuntimeError('Signed helper exited: ' + str(child.returncode))
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([peer], [], [], remaining)[0]:
                raise TimeoutError('Native dialog wire reply/event')
            chunk = peer.recv(65536)
            if not chunk:
                raise RuntimeError('Native dialog wire closed')
            buffer += chunk
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                message = json.loads(line)
                messages.append(message)
                with (out / 'wire.jsonl').open('a') as trace:
                    trace.write(json.dumps(message) + '\n')

    def send(method, **params):
        nonlocal serial
        serial += 1
        token = str(serial)
        peer.sendall((json.dumps({'v': 1, 'id': token, 'method': method, 'params': params}) + '\n').encode())
        return token

    def reply(token, error=False):
        value = take(lambda row: row.get('id') == token)
        if error:
            assert 'error' in value, value
        else:
            assert 'error' not in value, value
        return value.get('result')

    def ask(method, **params):
        return reply(send(method, **params))

    try:
        with tempfile.TemporaryDirectory(prefix='yad-', dir='/tmp') as temporary, (out / 'helper.log').open('w') as log:
            root = Path(temporary)
            os.chmod(root, 0o700)
            endpoint = root / 'core.sock'
            child = subprocess.Popen([summary['helper'], '--socket=' + str(endpoint), '--data-root=' + str(root / 'data'),
                                      '--use-mock-keychain', '--no-default-browser-check'], stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while not endpoint.exists():
                if child.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('Signed native helper did not start')
                time.sleep(.05)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.connect(str(endpoint))
            ask('hello')
            ask('profile.open', profile='agent-dialog-proof', private=True)
            tab = ask('tab.create', profile='agent-dialog-proof', url='')['tab']
            ask('scripts.install', tab=tab, scripts=[{'world': 'agent-proof', 'source': 'globalThis.nativeProofInstalled=true',
                                                    'end': False, 'mainOnly': True}], relays={})
            before = ask('tab.state', tab=tab)
            # Integration deliberately starts a blank document so scripts are
            # armed before the first real navigation. HasDocument can lag;
            # the helper's completed ScriptAttach is the contract here.
            check('pre-navigation scripts attach on the blank bootstrap',
                  before['url'] in ('', 'about:blank') and before['devToolsReady'] is True)
            url = 'http://127.0.0.1:' + str(server.server_port) + '/fixture'
            ask('tab.navigate', tab=tab, url=url)
            deadline = time.monotonic() + 30
            while True:
                state = ask('tab.state', tab=tab)
                if state['url'] == url and state['devToolsReady'] and not state['loading']:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError('First native document ready')
                time.sleep(.05)
            check('first real navigation has no synthetic Back entry', state['canGoBack'] is False)
            installed = ask('script.evaluate', tab=tab, world='agent-proof', function='function(){return globalThis.nativeProofInstalled===true}')
            check('staged isolated script is applied to the first document', installed is True)
            other = ask('tab.create', profile='agent-dialog-proof', url='')['tab']
            for kind in ('confirm', 'prompt', 'alert'):
                expression = kind + "('Native continuation fixture'" + (",'default'" if kind == 'prompt' else '') + ')'
                pending = send('script.document', tab=tab, expression=expression)
                event = take(lambda row: row.get('event') == 'dialog.open' and row.get('params', {}).get('tab') == tab)
                question = event['params']
                check(kind + ' uses a native request and copied origin', question['kind'] == kind and bool(question['request'])
                      and question['origin'].startswith('http://127.0.0.1:'))
                reply(send('dialog.reply', tab=other, request=question['request'], accept=True), error=True)
                reply(send('dialog.reply', tab=tab, request='stale-native-request', accept=True), error=True)
                check(kind + ' rejects a stale token and the wrong tab', True)
                values = {'tab': tab, 'accept': True, 'text': 'native-answer'}
                # Keep one old tab-scoped wire-v1 caller in the acceptance.
                if kind != 'alert':
                    values['request'] = question['request']
                ask('dialog.reply', **values)
                result = reply(pending)
                check(kind + ' resumes its original script', result == ('native-answer' if kind == 'prompt' else True if kind == 'confirm' else None))
                reply(send('dialog.reply', tab=tab, request=question['request'], accept=True), error=True)
                check(kind + ' callback cannot be answered twice', True)
            ask('shutdown')
            child.wait(timeout=20)
            check('native helper shuts down cleanly', child.returncode == 0)
            summary['passed'] = True
    except Exception:
        summary['error'] = traceback.format_exc()
        raise
    finally:
        if peer is not None:
            peer.close()
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=5)
        server.shutdown(); server.server_close()
        (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    run(args.app.resolve(), args.out.resolve())
