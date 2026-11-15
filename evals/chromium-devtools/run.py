#!/usr/bin/env python3
"""Chrome's DevTools on a Chromium tab, by hand, with pictures to look at.

Farm only:
  ./farm exec --display --needs capture,foreground,pointer --name "…" -- \
    bash evals/chromium-devtools/run.sh HOST:/path/App.app [scenario,…]

Keys, clicks and menus are real events (window-tiling's pointer.py). What it
writes in devtools.json is only what a picture needs to be found; the pictures
are the result.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import http.server
import traceback

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('r1s', ROOT / 'scripts/cef/r1-scenarios.py')
r1s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r1s)

REACT = 'fmkadmapgofadopljbjfkapdkoienihi'
SDK = "const S = await import('devtools://devtools/bundled/core/sdk/sdk.js'); const U = await import('devtools://devtools/bundled/ui/legacy/legacy.js');"
PICKED = SDK + "const n = U.Context.Context.instance().flavor(S.DOMModel.DOMNode); return n ? {name: n.nodeName(), id: n.getAttribute('id')} : null;"

r1s.FIXTURES['/dt'] = b'''<!doctype html><title>DT probe</title>
<style>body{margin:0;font:28px system-ui}#band{background:#ff00aa;height:160px;margin:0}#para{height:120px;background:#00ccff;margin:0}</style>
<h1 id=band>Band heading</h1><p id=para>Paragraph text</p>
<button id=b style="font-size:28px" onclick="document.title='DT clicked '+(++window.n||(window.n=1))">click me</button>
<script>console.log('devtools-probe-log');console.warn('devtools-probe-warn');fetch('/dt.json?probe=1').then(r=>r.text())</script>'''
r1s.FIXTURES['/dt.json'] = b'{"probe":1}'

PY = next(p for p in [sys.executable, '/usr/bin/python3', '/opt/homebrew/bin/python3', '/usr/local/bin/python3']
          if subprocess.run([p, '-c', 'import Quartz,AppKit,ApplicationServices'], capture_output=True).returncode == 0)
POINTER = str(ROOT / 'evals/window-tiling/pointer.py')


def ptr(*a, timeout=30):
    r = subprocess.run([PY, POINTER, *map(str, a)], capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        return {'raw': r.stdout[-500:], 'err': r.stderr[-500:]}


class Run:
    def __init__(self, app, out, base):
        self.app, self.out, self.base = app, out, base
        self.w = r1s.World(app, out, base)
        self.n = 0
        self.log = []

    def say(self, tag, **kw):
        kw['tag'] = tag
        self.log.append(kw)
        (self.out / 'devtools.json').write_text(json.dumps(self.log, indent=2, default=str))
        print(json.dumps(kw, default=str)[:1200], flush=True)

    def pids(self):
        return {p['pid'] for p in r1s.bundle_processes(self.app)}

    def windows(self):
        """Every on-screen window of the bundle, helpers too."""
        ids = self.pids()
        rows = ptr('near', 0, 0, 20000, 20000).get('windows', [])
        return [r for r in rows if r['pid'] in ids]

    def main(self):
        rows = [r for r in self.windows() if r['layer'] == 0 and r['frame'][2] > 50 and r['frame'][3] > 30]
        return max(rows, key=lambda r: r['frame'][2] * r['frame'][3])

    def shot(self, tag):
        self.n += 1
        stem = f'{self.n:02d}-{tag}'
        x, y, ww, hh = self.main()['frame']
        ptr('shot', x, y, ww, hh, self.out / (stem + '.png'))
        return stem

    def focus(self):
        x, y, ww, hh = self.main()['frame']
        ptr('click', x + ww * 0.6, y + 10)
        time.sleep(.3)

    def key(self, code, mods='', focus=False):
        if focus:
            self.focus()
        return ptr('key', code, mods)

    def type(self, codes):
        for c in codes:
            ptr('key', *c) if isinstance(c, tuple) else ptr('key', c)
            time.sleep(.05)

    def frontend(self, tab, body=None):
        return self.w.cr(tab, op='dev-frontend', **({'body': body} if body else {}))

    def state(self):
        return self.w.ask(do='probe')['dev']

    def card(self):
        """The card in screen points."""
        card = self.state()['card']
        x, y, _, _ = self.main()['frame']
        return [x + card[0], y + card[1], card[2], card[3]]

    def ready(self, tab, timeout=30):
        def up():
            s = self.frontend(tab)
            return s if s.get('ready') and s.get('surface') else None
        return r1s.wait_for(up, 'frontend did not come up', timeout)

    def head(self, title):
        """A head button pressed by a real click, found through Accessibility."""
        x, y, ww, hh = self.card()
        rows = ptr('dump', self.w.proc.pid, x, y, ww, 34).get('found', [])
        hit = [r for r in rows if title.lower() in str(r.get('title') or r.get('label') or r.get('value') or '').lower() and r.get('frame')]
        if not hit:
            self.say('head-miss', title=title, seen=[(r.get('role'), r.get('title'), r.get('label')) for r in rows][:40])
            return False
        f = hit[0]['frame']
        ptr('click', f[0] + f[2] / 2, f[1] + f[3] / 2)
        time.sleep(.8)
        return True

    def fresh(self, url=None):
        tab = self.w.open(url or self.base + '/dt')
        self.w.loaded(tab)
        time.sleep(1.2)
        return tab

    def page_point(self, tab, selector):
        """Screen point of an element's middle, from the page's own numbers."""
        box = self.w.js(tab, "const r=document.querySelector(%s).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}" % json.dumps(selector))
        place = self.state().get('chromiumPage') or []
        x, y, _, _ = self.main()['frame']
        return x + place[0] + box['x'], y + place[1] + box['y']


# Key codes
KEY = {'1': 18, 'plus': (24, 'shift'), 'return': 36, 'i': 34, 'j': 38, 'c': 8}
OPTCMD = 'option,command'


def s_open(R, r):
    """Each of the ways in, from a closed card, on the same page."""
    t = R.fresh()
    R.shot('page')
    R.key(KEY['i'], OPTCMD, focus=True)
    r['i'] = R.ready(t)
    time.sleep(1)
    r['i_dev'] = R.state()
    R.shot('opt-cmd-i')
    R.key(KEY['i'], OPTCMD)
    time.sleep(1.5)
    r['i_again'] = {'open': R.state()['open'], 'frontend': R.frontend(t)['frontend'], 'windows': len(R.windows())}
    R.shot('opt-cmd-i-closed')
    # The menu, not ⌥⌘J: that key can belong to another app on a test Mac.
    r1s.ax_press_menu(R.w.proc.pid, 'JavaScript Console')
    r['j'] = R.ready(t)
    time.sleep(1)
    R.shot('opt-cmd-j')
    r['j_pane'] = R.state()['pane']
    R.w.ask(do='ui', devtools=False)
    time.sleep(1.5)
    R.key(KEY['c'], OPTCMD)
    time.sleep(2)
    r['c'] = R.frontend(t)
    R.shot('opt-cmd-c')
    R.key(53)
    R.w.ask(do='ui', devtools=False)
    time.sleep(1.5)
    for item in ('Developer Tools', 'JavaScript Console', 'Inspect Element'):
        r['menu ' + item] = ptr('press', R.w.proc.pid, 'View', 'Developer', item)
        time.sleep(3)
        r['menu state ' + item] = R.frontend(t)
        R.shot('menu-' + item.replace(' ', '-'))
        R.w.ask(do='ui', devtools=False)
        time.sleep(1.5)


def s_panels(R, r):
    """Elements, Console with real typing, Network, Sources: this page's own."""
    t = R.fresh()
    R.key(KEY['i'], OPTCMD, focus=True)
    R.ready(t)
    time.sleep(1)
    r['elements_click'] = R.head('Elements')
    R.shot('elements')
    r['console_click'] = R.head('Console')
    time.sleep(.8)
    R.shot('console-logs')
    # The prompt, with the keyboard: 1+1 Return.
    R.type([KEY['1'], KEY['plus'], KEY['1']])
    time.sleep(.4)
    R.shot('console-typed')
    R.key(KEY['return'])
    time.sleep(1)
    R.shot('console-two')
    r['console_read'] = R.frontend(t, "return [...document.querySelectorAll('*')].length")
    r['network_click'] = R.head('Network')
    R.w.cr(t, op='navigate', url=R.base + '/dt?again=1')
    R.w.loaded(t)
    time.sleep(2)
    R.shot('network-requests')
    r['sources_click'] = R.head('Sources')
    time.sleep(1.5)
    R.shot('sources')
    for name in ('Performance', 'Application', 'Memory', 'Security'):
        r[name] = R.head(name)
        time.sleep(1)
        R.shot(name.lower())
    r['state'] = R.frontend(t)
    R.w.ask(do='ui', devtools=False)
    time.sleep(1)


def s_inspect(R, r):
    """The menu's Inspect Element and the picker each select that element."""
    t = R.fresh()
    R.focus()
    x, y = R.page_point(t, '#band')
    ptr('rclick', x, y)
    time.sleep(1)
    items = ptr('popup', R.w.proc.pid).get('found', [])
    r['menu'] = [i.get('title') for i in items]
    R.shot('context-menu')
    row = next((i for i in items if 'Inspect' in (i.get('title') or '')), None)
    if row:
        f = row['frame']
        ptr('click', f[0] + f[2] / 2, f[1] + f[3] / 2)
    else:
        # The menu reads as no element here; the fourth row hangs this far from the press.
        ptr('click', x + 86, y + 100)
    R.ready(t)
    time.sleep(2)
    r['picked_band'] = R.frontend(t, PICKED).get('value')
    R.shot('inspected-band')
    # The picker, by the head's button, then a real click on the page.
    x, y = R.page_point(t, '#para')
    R.key(KEY['c'], OPTCMD)
    time.sleep(1)
    r['picking'] = R.frontend(t)['picking']
    ptr('move', x, y)
    time.sleep(.6)
    R.shot('picker-hover')
    ptr('click', x, y)
    time.sleep(1.2)
    r['picked_para'] = R.frontend(t, PICKED).get('value')
    r['not_picking'] = not R.frontend(t)['picking']
    R.shot('picked-para')
    assert r['picked_band'] == {'name': 'H1', 'id': 'band'} and r['picked_para'] == {'name': 'P', 'id': 'para'}, r
    R.w.ask(do='ui', devtools=False)
    time.sleep(1)


def s_dock(R, r):
    """Sides and a dragged edge keep both drawn; closing leaves nothing."""
    t = R.fresh()
    R.key(KEY['i'], OPTCMD, focus=True)
    R.ready(t)
    time.sleep(1)
    before = sorted(w['number'] for w in R.windows())
    r['windows_open'] = before
    for side in ('bottom', 'left', 'right'):
        R.w.ask(do='ui', devside=side)
        time.sleep(1.5)
        r[side] = {'frontend': R.frontend(t), 'card': R.card(), 'pageJS': R.w.js(t, 'return [innerWidth,innerHeight]')}
        R.shot('dock-' + side)
    x, y, ww, hh = R.card()
    # The edge, in the air between page and card, dragged by hand.
    ptr('drag', x - 4, y + hh / 2, x - 260, y + hh / 2, .5)
    time.sleep(1.5)
    r['dragged'] = {'frontend': R.frontend(t), 'card': R.card(), 'pageJS': R.w.js(t, 'return [innerWidth,innerHeight]')}
    R.shot('dock-dragged')
    R.key(KEY['i'], OPTCMD, focus=True)
    time.sleep(2)
    r['closed'] = {'open': R.state()['open'], 'frontend': R.frontend(t)['frontend'], 'windows': sorted(w['number'] for w in R.windows()),
                   'all': [(w['owner'], w['name'], w['frame']) for w in R.windows()]}
    R.shot('closed')
    x, y = R.page_point(t, '#b')
    ptr('click', x, y)
    time.sleep(.8)
    r['page_works'] = R.w.js(t, 'return document.title')
    assert r['page_works'].startswith('DT clicked'), r['page_works']


def s_webkit(R, r):
    """A WebKit tab's card as before, and each tab its own on the way back and forth."""
    c = R.fresh()
    R.key(KEY['i'], OPTCMD, focus=True)
    R.ready(c)
    time.sleep(1)
    R.shot('chromium-tab-card')
    k = R.w.ask(do='usage-open', url='https://www.netflix.com/', foreground=True)['id']
    R.w.ask(do='select', id=k)
    time.sleep(6)
    r['engine'] = R.w.ask(do='page-engine', id=k)
    r['card_on_webkit_arrival'] = R.state()['open']
    R.shot('webkit-tab-no-card')
    R.key(KEY['i'], OPTCMD, focus=True)
    time.sleep(4)
    r['webkit_dev'] = R.state()
    R.w.ask(do='ui', devpane='elements')
    time.sleep(2)
    R.shot('webkit-elements')
    R.w.ask(do='ui', devpane='console')
    time.sleep(1)
    R.shot('webkit-console')
    R.w.ask(do='ui', devpane='network')
    time.sleep(2)
    R.shot('webkit-network')
    R.w.ask(do='select', id=c)
    time.sleep(2)
    r['back_chromium'] = {'dev': R.state(), 'frontend': R.frontend(c)}
    R.shot('back-on-chromium')
    R.w.ask(do='select', id=k)
    time.sleep(2)
    r['back_webkit'] = R.state()
    R.shot('back-on-webkit')
    R.w.ask(do='select', id=c)
    time.sleep(1.5)
    R.w.ask(do='ui', devtools=False)
    time.sleep(1)


def s_react(R, r):
    """React Developer Tools, the real one from the store, on a real React page."""
    r1s.store_install(R.w, r, REACT, 'https://chromewebstore.google.com/detail/' + REACT)
    t = R.w.open('https://react.dev/')
    R.w.loaded(t, 'react.dev', 60)
    time.sleep(3)
    R.key(KEY['i'], OPTCMD, focus=True)
    R.ready(t)
    def panels():
        s = R.frontend(t)
        return s if s.get('panels') else None
    r['panels'] = r1s.wait_for(panels, 'React panels did not appear', 30)
    time.sleep(1)
    R.shot('react-head')
    r['components'] = R.head('Components')
    time.sleep(3)
    R.shot('react-components')
    r['profiler'] = R.head('Profiler')
    time.sleep(2)
    R.shot('react-profiler')
    R.w.ask(do='ui', devtools=False)
    time.sleep(1)


SCENARIOS = {'open': s_open, 'panels': s_panels, 'inspect': s_inspect, 'dock': s_dock, 'webkit': s_webkit, 'react': s_react}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--app', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--only', default='')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), r1s.Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    R = Run(args.app.resolve(), args.out, f'http://127.0.0.1:{server.server_port}')
    only = [s for s in args.only.split(',') if s]
    failed = []
    try:
        for name, run in SCENARIOS.items():
            if only and name not in only:
                continue
            row = {}
            try:
                print('==', name, flush=True)
                run(R, row)
                R.say(name, passed=True, **row)
            except Exception as error:
                failed.append(name)
                R.say(name, passed=False, error=repr(error)[:1500], trace=traceback.format_exc()[-1500:], **row)
                try:
                    R.shot(name + '-failure')
                    R.w.ask(do='ui', devtools=False)
                except Exception:
                    pass
    finally:
        q = {'before': len(R.pids())}
        try:
            R.w.ask(do='quit-ask', yes=True, timeout=8)
        except Exception as error:
            q['reply'] = repr(error)
        end = time.monotonic() + 45
        while R.w.proc.poll() is None and time.monotonic() < end:
            try:
                if R.w.ask(do='ui', question='state', timeout=3).get('title'):
                    R.w.ask(do='question', yes=True, timeout=3)
            except Exception:
                pass
            time.sleep(1)
        q['exited'] = R.w.proc.poll() is not None
        end = time.monotonic() + 15
        while R.pids() and time.monotonic() < end:
            time.sleep(.5)
        q['left'] = r1s.bundle_processes(R.app)
        R.say('quit', **q)
        for row in q['left']:
            try:
                os.kill(row['pid'], 9)
            except OSError:
                pass
        if R.w.proc.poll() is None:
            R.w.proc.kill()
        subprocess.run(['defaults', 'delete', R.w.domain], capture_output=True)
        server.shutdown()
        txt = (args.out / 'browser.log').read_text(errors='replace') if (args.out / 'browser.log').exists() else ''
        (args.out / 'log-devtools.txt').write_text('\n'.join(l for l in txt.splitlines() if any(k in l.lower() for k in ('devtools', 'dcheck', 'fatal', 'check failed')))[-20000:])
    print('FAILED', failed)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
