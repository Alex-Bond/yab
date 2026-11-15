#!/usr/bin/env python3
"""Choosing an engine on the signed YAB_CEF=1 app, with real input: the real
pointer on the real menus (CGEvents, evals/window-tiling/pointer.py), real keys.

A world with live WebKit tabs across spaces and sleeping ones. Default engine
to Chromium: the menu says so, a new tab is Chromium, live tabs keep their
document, a woken tab is Chromium, a restart keeps it, then back to WebKit.
⌘K Open in moves one tab. A beforeunload page: Stay keeps it, Leave moves it.
Typed text is asked about. Netflix still goes to WebKit.

Every step records its result and a failure doesn't stop the next one.
Farm only: --display --needs capture,pointer,accessibility.
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
import traceback
import uuid

HERE = Path(__file__).resolve().parent
EVALS = HERE.parent
sys.path.insert(0, str(EVALS))
sys.path.insert(0, str(EVALS / 'chromium-drm'))
sys.path.insert(0, str(EVALS / 'chromium-tabs'))
from run import launch_exact, wait_for  # noqa: E402
from probe_capture import picture  # noqa: E402
from capture_menus import picture_with_menus  # noqa: E402
import yab_socket  # noqa: E402
import ax  # noqa: E402
import Quartz  # noqa: E402

POINTER = EVALS / 'window-tiling/pointer.py'
LIVE = int(os.environ.get('CHOOSE_LIVE', 40))
OTHER = int(os.environ.get('CHOOSE_OTHER', 12))
ASLEEP = int(os.environ.get('CHOOSE_ASLEEP', 10))

FORM = '<input id=f style="font-size:30px;width:700px;height:70px"><p><textarea id=t rows=3 style="font-size:24px;width:700px"></textarea>'
PAGES = {
    '/form': '<!doctype html><meta charset=utf-8><title>Typed form</title><body style="font:24px system-ui;padding:30px"><h1>Typed form</h1>' + FORM,
    '/ask': '<!doctype html><meta charset=utf-8><title>Asks to leave</title><body style="font:24px system-ui;padding:30px"><h1>Asks to leave</h1>' + FORM
            + '<script>addEventListener("beforeunload",e=>{e.preventDefault();e.returnValue="x"})</script>',
}


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        body = PAGES.get(path)
        if body is None:
            body = f'<!doctype html><meta charset=utf-8><title>Tab {path}</title><body style="font:30px system-ui;padding:30px">Tab {path}<script>document.body.append(" "+(navigator.userAgent.includes("Chrome/")?"Chromium":"WebKit"))</script>'
        data = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def hand(*words):
    done = subprocess.run([sys.executable, str(POINTER), *map(str, words)], capture_output=True, text=True, timeout=30)
    if done.returncode:
        raise RuntimeError(f'pointer {words}: {done.stderr.strip() or done.stdout.strip()}')
    return done.stdout


def type_text(text):
    for ch in text:
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(ch), ch)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
            time.sleep(.012)


KEY = {'k': 40, ',': 43, 'q': 12, 't': 17, 'l': 37}


class World:
    def __init__(self, app, out, port):
        self.app, self.out, self.port = app, out, port
        self.name = 'choose-' + uuid.uuid4().hex[:8]
        self.domain = 'dev.serafim.fast.test.' + self.name
        self.sock = Path.home() / 'Library/Application Support' / f'Yab ({self.name})' / 'bench.sock'
        self.shots = 0
        self.report = {'app': str(app), 'checks': {}, 'states': {}, 'errors': [], 'pictures': []}
        values = {'bench': True, 'welcomed': True, 'mail': False, 'hints.noticing': False, 'searchSuggest': False, 'dev.offer': False,
                  'shield': False, 'ApplePersistenceIgnoreState': True, 'NSQuitAlwaysKeepsWindows': False}
        plist = out / 'defaults.plist'
        plist.write_bytes(plistlib.dumps(values))
        subprocess.run(['defaults', 'import', self.domain, str(plist)], check=True, timeout=20)
        self.launch()

    def launch(self):
        # YAB_ENGINE empty: only the persisted choice may pick the engine.
        self.proc = launch_exact(self.app, {'YAB_PROBE': self.name, 'YAB_HISTORY': 'own', 'YAB_ENGINE': '', 'YAB_HEADLESS': '0',
                                            'YAB_AGENT_CLAUDE': '/usr/bin/true', 'YAB_AGENT_CODEX': '/nonexistent/x'},
                                 self.out, foreground=True)
        self.ask = yab_socket.kwasker(self.sock, timeout=60, strict=True, takes_timeout=True,
                                      fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))

        def ready():
            if not self.sock.exists():
                return False
            try:
                self.ask(do='ui', welcome=False, sidebar=True)
                return True
            except (ConnectionRefusedError, FileNotFoundError, RuntimeError):
                return False
        wait_for(ready, 'bench not ready', 90)

    @property
    def pid(self):
        return self.proc.pid

    def check(self, name, value, detail=None):
        self.report['checks'][name] = bool(value)
        if detail is not None:
            self.report['states'][name] = detail
        print(('ok  ' if value else 'FAIL'), name, detail if detail is not None else '', flush=True)

    def url(self, path, host=None):
        return f'http://{host or "127.0.0.1"}:{self.port}{path}'

    def open(self, url, foreground=True):
        tab = self.ask(do='usage-open', url=url, foreground=foreground)['id']
        if foreground:
            self.ask(do='select', id=tab)
        return tab

    def state(self, tab):
        return self.ask(do='chromium-drm', id=tab)

    def facts(self, tab):
        """Reads a tab with no page without building one."""
        return self.ask(do='chromium-drm', id=tab, op='site-engine')

    def js(self, tab, body):
        return self.ask(do='chromium-drm', id=tab, op='script', body=body)['value']

    def loaded(self, tab, kind=None, timeout=45):
        def done():
            s = self.state(tab)
            if s['loading'] or (kind and s['engine'] != kind):
                return None
            if s['engine'] == 'chromium' and not s.get('context'):
                return None
            return s
        return wait_for(done, f'{tab} not loaded in {kind}', timeout)

    def front(self):
        """A click brings Yab forward where activation alone doesn't, and
        clears the question localhost fixtures raise."""
        try:
            if self.ask(do='ui', question='state', timeout=3).get('title'):
                self.ask(do='question', yes=False, timeout=3)
        except Exception:
            pass
        rows = [w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, 0)
                if w.get('kCGWindowOwnerPID') == self.pid and w.get('kCGWindowLayer') == 0
                and w['kCGWindowBounds']['Width'] > 300]
        if rows:
            box = max(rows, key=lambda w: w['kCGWindowBounds']['Width'] * w['kCGWindowBounds']['Height'])['kCGWindowBounds']
            hand('click', box['X'] + box['Width'] * .6, box['Y'] + 10)
        time.sleep(.4)

    def key(self, letter, mods='command'):
        hand('key', KEY[letter], mods)

    def click(self, frame):
        hand('click', frame[0] + frame[2] / 2, frame[1] + frame[3] / 2)

    def named(self, *words, within=None):
        """Elements with exactly these words as title, value or description."""
        found = []
        for element, _ in ax.walk(ax.app(self.pid)):
            for attribute in ('AXTitle', 'AXValue', 'AXDescription'):
                said = ax.value(element, attribute)
                # SwiftUI rows read "Title, detail".
                if isinstance(said, str) and (said in words or said.split(', ')[0] in words):
                    box = ax.frame(element)
                    if box and box[2] > 0 and box[3] > 0 and (within is None or ax.inside(box, within)):
                        found.append({'role': ax.value(element, 'AXRole'), 'frame': box, 'said': said, 'element': element})
                    break
        return found

    def dump(self, name):
        (self.out / (name + '-ax.txt')).write_text(ax.dump(self.pid))

    def shot(self, name, tab=None, menus=False, settings=False):
        self.shots += 1
        path = self.out / f'{self.shots:02d}-{name}.png'
        try:
            if settings:
                listed = self.ask(do='ui', windows=True)['windows']
                number = next(w['id'] for w in listed if 'Settings' in w['kind'] or w['title'] in ('General', 'Settings', 'Engines for Sites'))
            elif tab:
                self.ask(do='select', id=tab)
                number = wait_for(lambda: self.state(tab)['window'] or None, 'no window', 10)
            else:
                number = 0
            meta = picture(self.pid, path, window_id=number)
            if menus:
                meta = picture_with_menus(self.pid, path, meta)
            self.report['pictures'].append({'file': path.name, 'capture': meta.get('capture')})
        except Exception as error:
            self.report['errors'].append(f'picture {name}: {error!r}')
        return path

    def quit(self):
        self.front()
        self.key('q')
        time.sleep(.5)
        try:
            self.key('q')
        except RuntimeError:
            pass
        try:
            self.ask(do='quit-ask', yes=True)
        except Exception:
            pass
        def gone():
            if self.proc.poll() is not None:
                return True
            # Pages with something typed ask first, each on its own: Leave.
            if self.named('Leave this page?'):
                hand('key', 36, '')
            return False
        wait_for(gone, 'did not quit', 40)

    def settings_rows(self):
        """Opens General and returns the Default engine menu's control."""
        self.front()
        self.key(',')
        wait_for(lambda: self.named('Default engine'), 'no Default engine row on General', 10)
        time.sleep(.5)
        button = [x for x in self.named('Default engine') if x['role'] == 'AXButton']
        if button:
            return {'frame': button[0]['frame'], 'element': button[0]['element'], 'title': None, 'value': None}
        row = self.named('Default engine')[0]['frame']
        mid = row[1] + row[3] / 2
        controls = []
        for element, _ in ax.walk(ax.app(self.pid)):
            if ax.value(element, 'AXRole') in ('AXMenuButton', 'AXPopUpButton', 'AXButton'):
                box = ax.frame(element)
                if box and box[2] > 0 and box[1] <= mid <= box[1] + box[3] and box[0] > row[0] + row[2]:
                    controls.append({'frame': box, 'element': element, 'title': ax.value(element, 'AXTitle'),
                                     'value': ax.value(element, 'AXValue')})
        if not controls:
            self.dump('no-engine-menu')
            raise RuntimeError('No control on the Default engine row')
        return max(controls, key=lambda c: c['frame'][0])

    def menu_says(self):
        control = self.settings_rows()
        said = [self.ax_text(control['element'])]
        return said[0]

    @staticmethod
    def ax_text(element):
        words = [ax.value(element, a) for a in ('AXTitle', 'AXValue', 'AXDescription')]
        for child, _ in ax.walk(element, limit=4):
            words.append(ax.value(child, 'AXValue'))
            words.append(ax.value(child, 'AXTitle'))
        return ' '.join(w for w in words if isinstance(w, str))

    def choose(self, title):
        """The real pointer: the menu pressed, then its line."""
        control = self.settings_rows()
        self.click(control['frame'])
        # Yab's DropMenu is a small window of text rows, not an NSMenu.
        def row():
            found = ax.item(self.pid, title)
            texts = [x for x in self.named(title) if x['role'] == 'AXStaticText']
            return found or (texts[0] if texts else None)
        line = wait_for(row, 'No menu line ' + title, 8)
        self.shot('menu-open-' + title, menus=True, settings=True)
        self.click(line['frame'])
        time.sleep(.8)
        return self.ax_text(self.settings_rows()['element'])

    def close_settings(self):
        hand('key', 13, 'command')  # ⌘W on Settings
        time.sleep(.4)

    def actions_row(self, title):
        """⌘K, then the row pressed by the real pointer."""
        self.front()
        tabs = self.ask(do='tabs')['tabs']
        target = next(t for t in tabs if t['active'])
        other = next(t for t in tabs if not t['active'] and not t['asleep'])
        # The field lists open tabs other than the one in front; ⌘K acts on the row.
        self.ask(do='select', id=other['id'])
        time.sleep(.4)
        self.ask(do='ui', newTab=True)
        time.sleep(.6)
        self.ask(do='ui', typed=target['title'])
        time.sleep(1.0)
        # The listed tab's row, wherever the search put it, with its ⌘K panel.
        self.ask(do='ui', pickOpen=True)
        rows = wait_for(lambda: self.named(title), 'No ⌘K row ' + title, 8)
        self.shot('cmdk-' + title.replace(' ', '-'))
        self.click(rows[0]['frame'])
        time.sleep(.6)
        self.ask(do='select', id=target['id'])

    def card(self, tab, words='Leave this page?', timeout=8):
        return wait_for(lambda: self.named(words) or None, 'No card: ' + words, timeout)

    def press_card(self, button):
        found = wait_for(lambda: [x for x in self.named(button) if x['role'] in ('AXButton', 'AXStaticText')] or None,
                         'No card button ' + button, 6)
        self.click(found[0]['frame'])
        time.sleep(.6)

    def type_into(self, tab, text):
        """A real press in the page's field and real keys."""
        self.ask(do='select', id=tab)
        self.front()
        rect = self.state(tab)
        box = self.js(tab, "const r=document.querySelector('#f').getBoundingClientRect();return [r.x,r.y,r.width,r.height]")
        win = next(w for w in self.ask(do='chromium-drm', id=tab, op='windows')['windows'] if w['number'] == rect['window'])
        page = self.ask(do='page-engine', id=tab)['pageRect']
        x = win['bounds']['X'] + page[0] + box[0] + box[2] / 2
        y = win['bounds']['Y'] + page[1] + box[1] + box[3] / 2
        hand('click', x, y)
        time.sleep(.4)
        type_text(text)
        time.sleep(.6)
        return self.js(tab, "return document.querySelector('#f').value")


def step(world, name, body):
    print('==', name, flush=True)
    try:
        body()
    except Exception as error:
        world.report['errors'].append({'step': name, 'error': repr(error), 'trace': traceback.format_exc()})
        world.check('step_' + name, False, repr(error))
        try:
            world.dump('fail-' + name)
            world.shot('fail-' + name)
        except Exception:
            pass
        try:
            hand('key', 53)
        except Exception:
            pass


def run(app, out):
    out.mkdir(parents=True, exist_ok=True)
    server = Server(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    w = World(app, out, server.server_address[1])
    held = {}

    def seed():
        w.ask(do='ui', sidebar=True)
        held['live'] = [w.open(w.url(f'/live/{n}', f'l{n}.localhost'), foreground=False) for n in range(LIVE)]
        held['asleep'] = [w.open(w.url(f'/asleep/{n}', f's{n}.localhost'), foreground=False) for n in range(ASLEEP)]
        held['netflix_asleep'] = w.open('https://www.netflix.com/title/80057281', foreground=False)
        w.ask(do='space', on=True, new='Other')
        w.ask(do='space', to='Other')
        held['other'] = [w.open(w.url(f'/other/{n}', f'o{n}.localhost'), foreground=False) for n in range(OTHER)]
        held['other_front'] = w.open(w.url('/other/front', 'of.localhost'))
        w.loaded(held['other_front'], 'webKit')
        for tab in held['other']:
            w.loaded(tab, 'webKit')
        held['other_marks'] = {tab: w.js(tab, 'window.__mark=performance.timeOrigin;return window.__mark') for tab in held['other']}
        names = w.ask(do='spaces').get('spaces') or []
        first = names[0]['name'] if names and isinstance(names[0], dict) else None
        if first:
            w.ask(do='space', to=first)
        for tab in held['live']:
            w.loaded(tab, 'webKit')
        for tab in held['asleep'] + [held['netflix_asleep']]:
            w.state(tab)
            said = w.ask(do='sleep', id=tab)
            w.report['states'].setdefault('slept', []).append(said)
        held['marks'] = {tab: w.js(tab, 'window.__mark=performance.timeOrigin;return window.__mark') for tab in held['live']}
        w.check('seed_live_webkit', all(w.facts(t)['engine'] == 'webKit' for t in held['live']))
        w.check('seed_asleep', all(x.get('asleep') for x in w.report['states'].get('slept', [])), w.report['states'].get('slept', [])[:2])
        held['front'] = held['live'][0]
        w.ask(do='select', id=held['front'])
        w.shot('seeded-webkit', held['front'])

    def pick_chromium():
        before = w.ax_text(w.settings_rows()['element'])
        w.check('menu_starts_webkit', 'WebKit' in before, before)
        w.shot('general-webkit', settings=True)
        said = w.choose('Chromium')
        w.check('menu_shows_chromium', 'Chromium' in said, said)
        w.shot('general-chromium', settings=True)
        w.close_settings()
        stored = subprocess.run(['defaults', 'read', w.domain, 'YabPageEngine'], capture_output=True, text=True).stdout.strip()
        w.check('preference_written', stored == 'chromium', stored)

    def live_unchanged():
        same = []
        for tab in held['live'][:LIVE]:
            s = w.facts(tab)
            mark = w.js(tab, 'return window.__mark')
            same.append(s['engine'] == 'webKit' and mark == held['marks'][tab])
        w.check('live_tabs_kept_engine_and_document', all(same), f'{sum(same)}/{len(same)}')
        foot = w.facts(held['front'])['foot']
        w.check('live_tab_foot_says_webkit', foot == 'WebKit', foot)
        w.shot('live-unchanged', held['front'])

    def other_space():
        w.ask(do='space', to='Other')
        time.sleep(.5)
        same = [w.facts(t)['engine'] == 'webKit' and w.js(t, 'return window.__mark') == held['other_marks'][t] for t in held['other']]
        w.check('other_space_live_kept', all(same), f'{sum(same)}/{len(same)}')
        fresh = w.open(w.url('/other/new', 'on.localhost'))
        s = w.loaded(fresh, 'chromium')
        w.check('other_space_new_tab_chromium', s['engine'] == 'chromium')
        names = w.ask(do='spaces').get('spaces') or []
        if names and isinstance(names[0], dict):
            w.ask(do='space', to=names[0]['name'])

    def new_tab():
        tab = w.open(w.url('/new', 'new.localhost'))
        s = w.loaded(tab, 'chromium')
        w.check('new_tab_chromium', s['engine'] == 'chromium' and s.get('context', 0) > 0, {k: s.get(k) for k in ('engine', 'context', 'helperPID')})
        helpers = subprocess.run(['pgrep', '-f', 'YabCore'], capture_output=True, text=True).stdout.split()
        w.check('helper_running', bool(helpers), len(helpers))
        foot = w.facts(tab)['foot']
        w.check('new_tab_foot_chromium', foot == 'Chromium', foot)
        rows = w.named(w.ask(do='tabs')['tabs'][-1]['row'])
        if rows:
            box = rows[0]['frame']
            hand('move', box[0] + box[2] / 2, box[1] + box[3] / 2)
            time.sleep(1.6)
            w.shot('hover-card-chromium')
            hand('move', 700, 500)
        held['new'] = tab

    def wake():
        tab = held['asleep'][0]
        foot = w.facts(tab)['foot']
        w.check('sleeping_foot_chromium_before_wake', foot == 'Chromium', foot)
        w.ask(do='select', id=tab)
        s = w.loaded(tab, 'chromium')
        w.check('woken_tab_chromium', s['engine'] == 'chromium')
        w.check('woken_ua_chromium', 'Chrome/' in w.js(tab, 'return navigator.userAgent'))
        w.shot('woken-chromium', tab)
        # A live tab put to sleep after the choice comes back on it too.
        late = held['live'][-1]
        said = w.ask(do='sleep', id=late)
        w.check('live_then_asleep', said.get('asleep'), said)
        w.ask(do='select', id=late)
        s = w.loaded(late, 'chromium')
        w.check('live_slept_then_woke_chromium', s['engine'] == 'chromium')

    def netflix():
        foot = w.facts(held['netflix_asleep'])['foot']
        w.check('netflix_asleep_foot_webkit', foot.startswith('WebKit'), foot)
        w.ask(do='select', id=held['netflix_asleep'])
        s = wait_for(lambda: (x if (x := w.state(held['netflix_asleep']))['engine'] == 'webKit' else None), 'netflix', 30)
        w.check('netflix_wakes_webkit', s['engine'] == 'webKit')
        tab = w.open('https://www.netflix.com/')
        s = wait_for(lambda: (x if (x := w.state(tab))['engine'] == 'webKit' else None), 'new netflix', 30)
        w.check('netflix_new_tab_webkit', s['engine'] == 'webKit', w.facts(tab)['foot'])
        w.shot('netflix-webkit', tab)
        # A live Chromium page going to Netflix: a person's navigation moves it.
        page = w.open(w.url('/to-netflix', 'tn.localhost'))
        w.loaded(page, 'chromium')
        w.ask(do='go', id=page, url='https://www.netflix.com/')
        s = wait_for(lambda: (x if (x := w.state(page))['engine'] == 'webKit' else None), 'chromium page to netflix', 45)
        w.check('live_chromium_navigates_to_webkit_for_netflix', s['engine'] == 'webKit')

    def open_in_one():
        tab = held['live'][1]
        other = held['live'][2]
        w.ask(do='select', id=tab)
        w.actions_row('Open in Chromium')
        s = w.loaded(tab, 'chromium')
        w.check('cmdk_open_in_moved_tab', s['engine'] == 'chromium')
        w.check('cmdk_reloaded_this_tab', w.js(tab, 'return window.__mark===undefined'))
        w.check('cmdk_left_other_tab', w.facts(other)['engine'] == 'webKit' and w.js(other, 'return window.__mark') == held['marks'][other])
        w.shot('cmdk-moved', tab)

    def always():
        tab = held['live'][3]
        w.ask(do='select', id=tab)
        w.actions_row('Always Open in Chromium')
        s = w.loaded(tab, 'chromium')
        w.check('always_open_in_moved_tab', s['engine'] == 'chromium')
        facts = w.facts(tab)
        w.check('always_open_wrote_rule', facts['choice'] == 'chromium', facts['choice'])

    def beforeunload(kind_from, words):
        def body():
            other = 'Chromium' if kind_from == 'webKit' else 'WebKit'
            tab = w.open(w.url('/ask', 'ask-' + words + '.localhost'))
            w.loaded(tab, kind_from)
            typed = w.type_into(tab, 'unsaved words')
            w.check(words + '_typed', typed == 'unsaved words', typed)
            mark = w.js(tab, 'window.__mark=1;return 1')
            w.actions_row('Open in ' + other)
            w.card(tab)
            w.shot(words + '-question', tab)
            w.press_card('Stay')
            time.sleep(1)
            s = w.state(tab)
            w.check(words + '_stay_keeps', s['engine'] == kind_from and w.js(tab, 'return window.__mark') == mark
                    and w.js(tab, "return document.querySelector('#f').value") == 'unsaved words', s['engine'])
            w.actions_row('Open in ' + other)
            w.card(tab)
            w.press_card('Leave')
            target = 'chromium' if kind_from == 'webKit' else 'webKit'
            s = w.loaded(tab, target)
            w.check(words + '_leave_moves', s['engine'] == target)
            w.check(words + '_tab_not_closed', any(t['id'] == tab for t in w.ask(do='tabs')['tabs']))
            carried = w.js(tab, "return document.querySelector('#f').value")
            w.report['states'][words + '_carried_text'] = carried
            w.shot(words + '-moved', tab)
        return body

    def typed_no_handler(kind_from, words):
        def body():
            other = 'Chromium' if kind_from == 'webKit' else 'WebKit'
            tab = w.open(w.url('/form', 'form-' + words + '.localhost'))
            w.loaded(tab, kind_from)
            typed = w.type_into(tab, 'typed words')
            w.check(words + '_typed', typed == 'typed words', typed)
            w.actions_row('Open in ' + other)
            w.card(tab)
            w.shot(words + '-yab-question', tab)
            w.press_card('Stay')
            time.sleep(.8)
            s = w.state(tab)
            w.check(words + '_stay_keeps_text', s['engine'] == kind_from
                    and w.js(tab, "return document.querySelector('#f').value") == 'typed words', s['engine'])
        return body

    def restart():
        w.quit()
        w.report['states']['first_exit'] = w.proc.poll()
        w.launch()
        tabs = wait_for(lambda: (t if len(t := w.ask(do='tabs')['tabs']) > 3 else None), 'no tabs back', 30)
        w.report['states']['restored'] = len(tabs)
        said = w.ax_text(w.settings_rows()['element'])
        w.check('restart_menu_chromium', 'Chromium' in said, said)
        w.shot('restart-general', settings=True)
        w.close_settings()
        tab = w.open(w.url('/restart', 'rs.localhost'))
        w.check('restart_new_tab_chromium', w.loaded(tab, 'chromium')['engine'] == 'chromium')
        plain = next((t for t in tabs if '/live/' in t['url']), None)
        if plain:
            foot = w.facts(plain['id'])['foot']
            w.check('restart_restored_tab_chromium', foot == 'Chromium', foot)
            w.ask(do='select', id=plain['id'])
            w.check('restart_restored_wakes_chromium', w.loaded(plain['id'], 'chromium')['engine'] == 'chromium')
        held['after'] = tab

    def pick_webkit():
        said = w.choose('WebKit')
        w.check('menu_back_to_webkit', 'WebKit' in said, said)
        w.close_settings()
        tab = w.open(w.url('/back', 'bk.localhost'))
        w.check('webkit_new_tab', w.loaded(tab, 'webKit')['engine'] == 'webKit')
        s = w.state(held['after'])
        w.check('chromium_tab_stays_after_webkit', s['engine'] == 'chromium', s['engine'])
        w.shot('back-to-webkit', tab)

    def sites_page():
        w.front()
        w.key(',')
        w.click(w.settings_rows()['frame'])
        rows = wait_for(lambda: [x for x in w.named('Engines for Sites') if x['role'] == 'AXStaticText'] or None,
                        'no Engines for Sites line', 8)
        w.shot('general-rows', menus=True, settings=True)
        w.click(rows[0]['frame'])
        wait_for(lambda: w.named('Add Site…') or None, 'no Add Site', 8)
        w.shot('engines-for-sites', settings=True)
        w.check('sites_page_opens', True)
        sidebar = [x for x in w.named('Engine') if x['role'] == 'AXStaticText' and x['frame'][2] < 100]
        w.check('no_engine_in_sidebar', not sidebar, [x['role'] for x in sidebar])
        w.close_settings()

    step(w, 'seed', seed)
    step(w, 'sites_page', sites_page)
    step(w, 'pick_chromium', pick_chromium)
    step(w, 'live_unchanged', live_unchanged)
    step(w, 'new_tab', new_tab)
    step(w, 'other_space', other_space)
    step(w, 'wake', wake)
    step(w, 'netflix', netflix)
    # Default Chromium: Open in WebKit questions a Chromium page. Against
    # WebKit tabs from before the choice for the other way round.
    step(w, 'open_in_one', open_in_one)
    step(w, 'always', always)
    step(w, 'typed_chromium', typed_no_handler('chromium', 'typedc'))
    step(w, 'beforeunload_chromium', beforeunload('chromium', 'askc'))
    step(w, 'restart', restart)
    step(w, 'pick_webkit', pick_webkit)
    step(w, 'typed_webkit', typed_no_handler('webKit', 'typedw'))
    step(w, 'beforeunload_webkit', beforeunload('webKit', 'askw'))

    w.report['ok'] = all(w.report['checks'].values()) and not w.report['errors']
    (out / 'result.json').write_text(json.dumps(w.report, indent=2, default=str))
    try:
        w.quit()
    except Exception:
        w.proc.kill()
    server.shutdown()
    print(json.dumps({'ok': w.report['ok'], 'failed': [k for k, v in w.report['checks'].items() if not v]}))
    return 0 if w.report['ok'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    a = parser.parse_args()
    sys.exit(run(a.app, a.out))
