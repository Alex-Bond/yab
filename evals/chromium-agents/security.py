"""Synthetic secret boundaries through real MCP tools, never real credentials."""
import http.server
import json
from pathlib import Path
import threading
import time

CANARY = 'SYNTHETIC_AGENT_PROTECTED_CANARY'


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.split('?', 1)[0]
        if name == '/secret':
            body = f'<title>Recovery phrase</title><h1>Recovery phrase</h1><input aria-label="Seed phrase" value="{CANARY}">'
        elif name.startswith('/many'):
            body = '<title>Many frames</title><h1>Frame inventory</h1><script>window.loaded=0</script>'
            for n in range(41):
                child = '/secret' if name == '/many-secret' and n == 40 else '/safe'
                body += f'<iframe onload="window.loaded++" src="http://localhost:{self.server.server_port}{child}" style="height:24px"></iframe>'
        elif name.startswith('/deep/'):
            depth = int(name.rsplit('/', 1)[1])
            body = '<title>Deep frames</title>'
            if depth < 33:
                body += f'<iframe src="http://localhost:{self.server.server_port}/deep/{depth + 1}"></iframe>'
        else:
            body = '<title>Safe agent fixture</title><h1>Ordinary account</h1><input aria-label="Full name"><button>Save draft</button>'
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

    def script(body):
        return ask(do='chromium', id=tab, op='script', body=body)['value']

    def refused(tool, **params):
        try:
            result = m(tool, tab=tab, **params)
        except AssertionError as error:
            result = str(error)
            assert CANARY not in result, 'Protected fixture contents leaked in an error'
            assert 'protected' in result.lower(), f'{tool} failed for another reason: {result}'
            return
        raise AssertionError(f'{tool} returned protected output: {result[:100]}')

    try:
        tab = prims.tab_of(m('open', url=base + '/safe'))
        detached = ask(do='agent-chromium-input-probe', id=tab)
        assert detached['detached'] and detached['value'] == 'Ada 日本', detached
        assert all(detached[key] for key in ('clicked', 'hovered', 'dragged')), detached
        events = detached['events']
        assert events['keys'] and all(events['keys']), detached
        assert events['clicks'] and all(events['clicks']), detached
        assert events['moves'] and all(events['moves']), detached
        summary['detached-trusted-input'] = {'passed': True, 'evidence': detached}
        shot = m.call_raw('tools/call', {'name': 'screenshot', 'arguments': {'tab': tab}})
        assert not shot.get('isError'), 'An ordinary page screenshot was refused'
        assert any(item.get('type') == 'image' and item.get('data') for item in shot.get('content', [])), 'Ordinary screenshot returned no image'
        summary['ordinary-screenshot'] = {'passed': True}
        script("document.body.innerHTML='<h1>Recovery phrase</h1><input aria-label=Seed_phrase value=" + CANARY + ">';window.agentKeys=0;window.agentClicks=0;addEventListener('keydown',()=>agentKeys++);addEventListener('click',()=>agentClicks++);return true")
        for tool, params in [('snapshot', {}), ('text', {}), ('screenshot', {}),
                             ('eval', {'js': 'document.body.innerText'}),
                             ('press', {'keys': 'a Enter'}), ('click', {'x': 200, 'y': 200}),
                             ('type', {'ref': 'e1', 'text': 'replace'})]:
            refused(tool, **params)
            summary['main-' + tool] = {'passed': True}
        assert script('return {keys:agentKeys,clicks:agentClicks}') == {'keys': 0, 'clicks': 0}
        summary['no-native-input'] = {'passed': True}
        m('navigate', tab=tab, url=base + '/safe')
        safe = m('snapshot', tab=tab)
        assert 'Ordinary account' in safe, safe
        summary['leave-protected-page'] = {'passed': True}
        race = ask(do='agent-chromium-input-probe', id=tab, probe='capture-race')
        assert race.get('blocked') is True and race.get('checks') == 2, race
        summary['capture-reply-refuses-new-secret'] = {'passed': True, 'evidence': race}
        # Snapshots recurse into open shadow roots. Their recovery material
        # must be refused by every read/input route before any output escapes.
        script("""const root = document.body.appendChild(document.createElement('div')).attachShadow({mode:'open'});
        const nested = root.appendChild(document.createElement('div')).attachShadow({mode:'open'});
        nested.innerHTML = '<h1>Recovery phrase</h1><input aria-label="Seed phrase" value=""" + CANARY + """>';
        return true""")
        for tool, params in [('snapshot', {}), ('text', {}), ('screenshot', {}),
                             ('eval', {'js': 'document.body.innerText'}),
                             ('press', {'keys': 'a Enter'}), ('click', {'x': 200, 'y': 200}),
                             ('type', {'ref': 'e1', 'text': 'replace'})]:
            refused(tool, **params)
            summary['shadow-' + tool] = {'passed': True}
        m('navigate', tab=tab, url=base + '/safe')
        assert 'Ordinary account' in m('snapshot', tab=tab)
        summary['leave-protected-shadow'] = {'passed': True}
        # Navigate with the trusted harness, retaining this MCP-owned tab.
        # The model-facing read begins only after every iframe's load event.
        ask(do='agent-go', id=tab, url=base + '/many-secret')
        until = time.monotonic() + 30
        while script('return window.loaded || 0') != 41:
            assert time.monotonic() < until, '41-frame fixture did not load'
            time.sleep(.1)
        for tool, params in [('snapshot', {}), ('text', {}), ('screenshot', {}),
                             ('eval', {'js': 'document.body.innerText'}), ('press', {'keys': 'Enter'})]:
            refused(tool, **params)
            summary['frame-41-' + tool] = {'passed': True}
        ask(do='agent-go', id=tab, url=base + '/many-safe')
        until = time.monotonic() + 30
        while script('return window.loaded || 0') != 41:
            assert time.monotonic() < until, '41 ordinary frames did not load'
            time.sleep(.1)
        safe = m('snapshot', tab=tab)
        assert 'Frame inventory' in safe, safe
        summary['many-safe-frames'] = {'passed': True}
        ask(do='agent-go', id=tab, url=base + '/deep/0')
        # Wait for the complete navigation, not just the outer document.
        until = time.monotonic() + 30
        while ask(do='chromium', id=tab).get('loading'):
            assert time.monotonic() < until, 'Deep fixture did not finish'
            time.sleep(.1)
        refused('snapshot')
        summary['depth-limit-refuses'] = {'passed': True}
    finally:
        if tab:
            try: m('close', tab=tab)
            except Exception: pass
        server.shutdown()
        server.server_close()
        (Path(out) / 'security.json').write_text(json.dumps(summary, indent=2))
    return summary
