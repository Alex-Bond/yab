"""Auto mode: a send-like key or point inside another site's frame is weighed
in that frame (Chromium runs it out of process). Synthetic fixture only."""
import http.server
import json
from pathlib import Path
import threading
import time

SENT = []


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.split('?', 1)[0]
        port = self.server.server_port
        if name == '/sent':
            SENT.append(self.path)
            body = 'ok'
        elif name == '/shadow':
            body = ('<title>Shadow compose</title><div id=host></div><script>'
                    'const root=host.attachShadow({mode:"open"});'
                    'root.innerHTML=\'<button style="position:fixed;left:10px;top:10px;width:200px;height:100px">Send message</button>\';'
                    'root.querySelector("button").onclick=()=>fetch("/sent?m=shadow");</script>')
        elif name == '/frame':
            body = ('<title>Chat widget</title><style>body{margin:0}</style>'
                    '<form id=f><input id=msg aria-label="Message" style="position:absolute;left:10px;top:10px;width:200px;height:30px">'
                    '<button id=send style="position:absolute;left:10px;top:60px;width:120px;height:30px">Send message</button></form>'
                    "<script>f.addEventListener('submit', e => { e.preventDefault(); fetch('/sent?m=' + encodeURIComponent(msg.value)); });</script>")
        else:
            body = ('<title>Support</title><h1>Support</h1><style>body{margin:0}h1{margin:0;height:40px}</style>'
                    f'<iframe id=fr src="http://localhost:{port}/frame" style="position:absolute;left:0;top:50px;width:400px;height:120px;border:0"></iframe>')
        body = ('<!doctype html><meta charset=utf-8>' + body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(m, ask, out, prims):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    summary = {}
    tab = None

    def refused(words, tool, **params):
        try:
            result = m(tool, tab=tab, **params)
        except AssertionError as error:
            text = str(error)
            expected = [words] if isinstance(words, str) else words
            assert all(word in text for word in expected), f'{tool} refused for another reason: {text}'
            return text
        raise AssertionError(f'{tool} was not weighed: {result[:200]}')

    def sent(count, seconds=3):
        until = time.monotonic() + seconds
        while len(SENT) < count and time.monotonic() < until: time.sleep(.1)
        return len(SENT)

    previous = ask(do='sync', action='approvals').get('asking', 'bypass')
    try:
        snap = m('open', url=base + '/')
        tab = prims.tab_of(snap)
        until = time.monotonic() + 20
        while 'Message' not in snap:
            assert time.monotonic() < until, 'frame field never reached the snapshot: ' + snap[-400:]
            time.sleep(.3)
            snap = m('snapshot', tab=tab)
        field = prims.ref(snap, r'textbox "Message')
        assert field.startswith('f'), f'field is not in a frame: {field}'
        m('click', tab=tab, ref=field)
        m('type', tab=tab, ref=field, text='hello from the agent')
        ask(do='sync', action='approvals', asking='auto')
        # MCP formats a held action as needs_user plus the actual question,
        # rather than preserving the bench's literal word "yes".
        summary['press-enter'] = {'passed': True, 'error': refused(['status: needs_user', 'Send message?'], 'press', keys='Enter')}
        assert sent(1, 2) == 0, SENT
        summary['press-not-sent'] = {'passed': True}
        # Cancel the synthetic pending question by closing its fixture through
        # the trusted harness. The independent point test must reach weighing,
        # not just repeat the previous tool's needs_user response.
        ask(do='close', id=tab)
        tab = None
        assert sent(1, .2) == 0, SENT
        snap = m('open', url=base + '/')
        tab = prims.tab_of(snap)
        box = ask(do='chromium', id=tab, op='script', body="const r=document.getElementById('fr').getBoundingClientRect(); return {x:r.left+70,y:r.top+75,w:innerWidth};")['value']
        summary['point-click'] = {'passed': True, 'error': refused("another site's frame", 'click',
            x=box['x'] * 1024 / box['w'], y=box['y'] * 1024 / box['w'])}
        assert sent(1, 2) == 0, SENT
        summary['point-not-sent'] = {'passed': True}
        m('close', tab=tab)
        tab = None
        snap = m('open', url=base + '/shadow')
        tab = prims.tab_of(snap)
        box = ask(do='chromium', id=tab, op='script', body='return {w:innerWidth};')['value']
        summary['shadow-point'] = {'passed': True, 'error': refused(
            ['status: needs_user', 'Send message?'], 'click',
            x=70 * 1024 / box['w'], y=60 * 1024 / box['w'])}
        assert sent(1, 2) == 0, SENT
        summary['shadow-point-not-sent'] = {'passed': True}
        ask(do='close', id=tab)
        tab = None
        # The same key in Bypass reaches the frame's field through CDP, in a
        # fresh tab: the question asked above stays with the old one.
        ask(do='sync', action='approvals', asking='bypass')
        snap = m('open', url=base + '/')
        tab = prims.tab_of(snap)
        until = time.monotonic() + 20
        while 'Message' not in snap:
            assert time.monotonic() < until, 'frame field never reached the snapshot: ' + snap[-400:]
            time.sleep(.3)
            snap = m('snapshot', tab=tab)
        field = prims.ref(snap, r'textbox "Message')
        m('click', tab=tab, ref=field)
        m('type', tab=tab, ref=field, text='hello in bypass')
        m('press', tab=tab, keys='Enter')
        assert sent(1, 5) == 1 and 'hello' in SENT[0], SENT
        summary['bypass-enter-sends'] = {'passed': True, 'sent': SENT[0]}
    finally:
        try: ask(do='sync', action='approvals', asking=previous)
        except Exception: pass
        if tab:
            try: m('close', tab=tab)
            except Exception: pass
        server.shutdown()
        server.server_close()
        (Path(out) / 'focus.json').write_text(json.dumps(summary, indent=2))
    return summary
