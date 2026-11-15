#!/usr/bin/env python3
"""Real signed CEF app: existing browser primitives plus iframe script proof."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import threading
import traceback
import time
import uuid

EVALS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVALS / 'chromium-scripts'))
sys.path.insert(0, str(EVALS))
sys.path.insert(0, str(EVALS / 'browse'))
from probe_capture import picture
from agent_launch import launch_exact, require_window, require_page_window
import yab_socket
import server
import prims

spec = importlib.util.spec_from_file_location('chromium_tabs', EVALS / 'chromium-tabs/run.py')
tabs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tabs)

sys.path[:0] = [str(EVALS / 'chromium-extensions'), str(EVALS / 'chromium-media')]
from prepared_lifetime import PreparedAppLifetime
from owned_mcp import OwnedMcp


# Cases that run on another fixture page, as prims.main maps them.
PAGES = {'cardmask': 'wallet/checkout-std', 'stale': 'button', 'iframe-user': 'button', 'nodownload': 'hover-menu'}
DEFAULT_CASES = ['button', 'react-form', 'editor', 'combobox', 'hover-menu', 'shadow', 'iframe-cross', 'csp', 'covered', 'delayed', 'virtual', 'drag', 'cardmask', 'reply', 'palette', 'seen', 'stale']


BUDGET = 1500  # seconds for the whole run; a hang fails with a reason, not a silent hold


def diagnose(ask):
    """After the first failed case: what each tab's page and agent world answer, and the script status."""
    try:
        rows = ask(do='tabs')['tabs']
    except Exception as error:
        print('diagnose: no tab list', repr(error), flush=True); return
    for row in rows[-3:]:
        tab = row.get('id')
        print('diagnose tab', {k: row.get(k) for k in ('id', 'url', 'title', 'engine')}, flush=True)
        for label, extra in (('info', {}), ('page world', {'op': 'script', 'body': 'return location.href'}),
                             ('agent world', {'op': 'script', 'world': 'yab-agent', 'body': 'return location.href'}), ('scripts', {'op': 'scripts'})):
            try:
                print('diagnose', label, json.dumps(ask(do='chromium', id=tab, **extra))[:1500], flush=True)
            except Exception as error:
                print('diagnose', label, 'FAILED', repr(error)[:300], flush=True)


def run(app, out, settle_open=False, security=False, only=None, geometry=False, focus=False, url_download=False, prepared_app=False):
    # Legacy browse fixtures include a direct bench socket with no explicit
    # timeout. Keep that existing case bounded without changing its assertions.
    socket.setdefaulttimeout(45)
    cases = DEFAULT_CASES if only is None else only
    if not cases or any(name not in prims.CASES for name in cases):
        raise ValueError('Expected nonempty existing browse primitive names')
    started = time.monotonic()
    deadline = started + BUDGET
    failures = []
    out.mkdir(parents=True, exist_ok=True)
    world = 'chromium-agents-' + uuid.uuid4().hex[:8]
    domain = 'dev.serafim.fast.test.' + world
    defaults = out / 'defaults.plist'
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False,
        'hints.noticing': False, 'searchSuggest': False, 'agents.asking': 'bypass'}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True)
    env = dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE='chromium',
               YAB_AGENT_CLAUDE='/usr/bin/true', YAB_AGENT_CODEX='/nonexistent/chromium')
    print('launching the signed app', flush=True)
    proc = tabs.launch_exact(app, env, out, foreground=True) if prepared_app else launch_exact(app, env, out)
    actual_app = Path(proc.binary).parents[2]
    print(f'app pid {proc.pid}', flush=True)
    sock = yab_socket.socket_path(world)
    ask = yab_socket.kwasker(sock, timeout=45, strict=True, takes_timeout=True,
                            fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
    summary = {'app': str(app), 'world': world, 'checks': {}, 'pictures': [], 'diagnostic_settle_open': settle_open, 'selected_cases': cases}
    summary['original_primitive_cases'] = [name for name in cases if name != 'dialog']
    summary['dialog_contract'] = 'native AskCard and fresh post-answer guard; original WebKit c_dialog not executed' if 'dialog' in cases else None
    servers = []
    lifetime = PreparedAppLifetime(actual_app, proc, Path(sock).parent, ask, out)
    clients, completed_clients = [], set()
    summary['prepared_app'] = prepared_app
    summary['actual_app'] = str(actual_app)
    summary['mcp_cleanup'] = []

    def new_client(label):
        client = OwnedMcp.__new__(OwnedMcp)
        clients.append((client, label))  # Retain original Popen even if initialize fails.
        (out / label).mkdir(parents=True, exist_ok=True)
        client.__init__(str(proc.binary), world, app=actual_app,
                        support=Path(sock).parent, out=out / label)
        return client

    def finish_client(client, label):
        if id(client) in completed_clients:
            return
        row = {'label': label, 'passed': False}
        try:
            client.close()  # Original stdio EOF only, never inherited terminate/kill.
            if client.lifetime is None:
                raise RuntimeError('MCP initialize created no original lifetime')
            row.update(client.lifetime.finish())
        except Exception as error:
            row['error'] = repr(error)
        summary['mcp_cleanup'].append(row)
        completed_clients.add(id(client))
        if row.get('passed') is not True:
            raise RuntimeError('Original MCP natural shutdown was not proven: ' + label)
    try:
        tabs.wait_for(lambda: Path(sock).exists(), 'No bench socket', 60)
        ask(do='ui', welcome=False, sidebar=True)
        print('bench socket up', flush=True)
        require_window(ask)
        print('ordinary window present', flush=True)
        # Reuse the project's deterministic agent eval without modifying it.
        prims.BIN = str(proc.binary)
        prims.WORLD = world
        probe_order = os.environ.get('YAB_CHROMIUM_SCRIPT_ORDER_PROBE') == '1'
        if probe_order:
            original_send = server.Handler.send
            def send(handler, code, body, kind='application/json', extra=None):
                if kind.startswith('text/html'):
                    binary = isinstance(body, bytes)
                    if binary: body = body.decode('utf-8')
                    probe = "<script nonce=yab>window.__yabOrderAtAuthorStart=sessionStorage.getItem('__yabScriptOrder');window.__yabOrderIsolated=typeof globalThis.__yabOrderWorld==='undefined';</script>"
                    at = body.find('>') + 1 if body.lower().startswith('<!doctype') else 0
                    body = body[:at] + probe + body[at:]
                    if binary: body = body.encode('utf-8')
                return original_send(handler, code, body, kind, extra)
            server.Handler.send = send
        summary['registration'] = []
        servers = server.serve()
        threading.Thread(target=servers[0].serve_forever, daemon=True).start()
        m = new_client('mcp-primitives')
        try:
            for name in cases:
                case_key = 'native-dialog-card' if name == 'dialog' else name
                prims.reset(name)
                tab = None
                shown = False
                if time.monotonic() > deadline: raise RuntimeError('Agent eval exceeded its time budget')
                print(f'[{time.monotonic() - started:6.1f}s] case {name} start', flush=True)
                try:
                    # Every primitive promises an agent-owned tab. Earlier
                    # cases deliberately hand tabs to the person; TabReuse
                    # correctly reuses those on the same fixture site.
                    # Remove only this isolated world's synthetic fixture tabs.
                    for row in ask(do='tabs')['tabs']:
                        if row.get('url', '').startswith(prims.BASE + '/'):
                            ask(do='close', id=row['id'])
                    snap = m('open', url=f'{prims.BASE}/{PAGES.get(name, name)}.html?task={prims.PREFIX}{name}')
                    tab = prims.tab_of(snap)
                    (out / (name + '-initial-open.txt')).write_text(snap)
                    if settle_open:
                        time.sleep(1)
                        snap = m('snapshot', tab=tab)
                    (out / (name + '-snapshot.txt')).write_text(snap)
                    if probe_order:
                        registration = ask(do='chromium', id=tab, op='script', body='return {order:window.__yabOrderAtAuthorStart,isolated:window.__yabOrderIsolated}')['value']
                        summary['registration'].append({'case': name, **registration})
                        assert registration == {'order': 'abc', 'isolated': True}, registration
                    if name == 'dialog':
                        # Chromium uses nav's native continuation and AskCard.
                        # The legacy c_dialog expects renderer reads while its
                        # confirm is held; retain it unchanged as WebKit proof.
                        import native_card
                        summary['native_card'] = native_card.run(m, ask, out, prims, tab, snap, proc.pid)
                    else:
                        prims.CASES[name](m, snap, tab)
                        if name == 'popup':
                            child = tabs.wait_for(lambda: next((row for row in ask(do='tabs')['tabs']
                                if row.get('url', '').startswith(prims.BASE + '/popup-code.html')), None),
                                'Native popup fixture tab did not appear', 15)
                            ask(do='select', id=child['id'])
                            state = require_page_window(ask, child['id'])
                            assert state.get('engine') == 'chromium', state
                            path = out / 'popup.png'
                            metadata = picture(proc.pid, path, window_id=state['window'])
                            assert metadata.get('capture') == 'ScreenCaptureKit', metadata
                            summary['popup_capture'] = {'passed': True, 'tab': child, 'capture': metadata}
                            summary['pictures'].append({'path': str(path), 'capture': metadata})
                    summary['checks'][case_key] = {'passed': True}
                    print(f'[{time.monotonic() - started:6.1f}s] case {name} passed', flush=True)
                except Exception as error:
                    summary['checks'][case_key] = {'passed': False, 'error': repr(error), 'traceback': traceback.format_exc()}
                    print(f'[{time.monotonic() - started:6.1f}s] case {name} FAILED {error!r}'[:400], flush=True)
                    failures.append(str(error)[:120])
                    if len(failures) == 1: diagnose(ask)
                    if len(failures) >= 3 and len(set(failures[-3:])) == 1:
                        raise RuntimeError('Three cases failed the same way: ' + failures[-1])
                    if isinstance(error, subprocess.TimeoutExpired):
                        # A hung app: say where, then stop instead of waiting out every case.
                        raise RuntimeError('The app stopped answering during ' + name)
                    if tab:
                        try:
                            (out / (name + '-scripts.json')).write_text(json.dumps(ask(do='chromium', id=tab, op='scripts'), indent=2))
                            (out / (name + '-retry-snapshot.txt')).write_text(m('snapshot', tab=tab))
                        except Exception as diagnosis:
                            summary['checks'][case_key]['diagnosis_error'] = repr(diagnosis)
                finally:
                    if tab and not shown:
                        try: m('close', tab=tab)
                        except Exception: pass
                        # iframe-user deliberately adopts this synthetic tab.
                        # MCP correctly leaves it with the person; remove it
                        # through the trusted fixture harness so later cases
                        # cannot reuse it and change their dialog ownership.
                        try:
                            if any(row['id'] == tab for row in ask(do='tabs')['tabs']):
                                ask(do='close', id=tab)
                        except Exception: pass
                (out / 'summary.json').write_text(json.dumps(summary, indent=2))
            if url_download:
                import url_download as url_checks
                try:
                    summary['url_download'] = url_checks.run(m, ask, out, prims)
                    summary['checks']['url-download'] = {'passed': True}
                except Exception as error:
                    summary['checks']['url-download'] = {'passed': False, 'error': repr(error), 'traceback': traceback.format_exc()}
            if security:
                import security as secret_checks
                try:
                    summary['security'] = secret_checks.run(m, ask, out, prims)
                    summary['checks']['security'] = {'passed': True}
                except Exception as error:
                    summary['checks']['security'] = {'passed': False, 'error': repr(error), 'traceback': traceback.format_exc()}
            if security or focus:
                import focus as focus_checks
                try:
                    summary['focus'] = focus_checks.run(m, ask, out, prims)
                    summary['checks']['focus'] = {'passed': True}
                except Exception as error:
                    summary['checks']['focus'] = {'passed': False, 'error': repr(error), 'traceback': traceback.format_exc()}
            if geometry:
                import geometry as geometry_checks
                try:
                    summary['geometry'] = geometry_checks.run(m, ask, out, prims, proc.pid)
                    summary['checks']['geometry'] = {'passed': True}
                except Exception as error:
                    summary['checks']['geometry'] = {'passed': False, 'error': repr(error), 'traceback': traceback.format_exc()}
        finally:
            finish_client(m, 'mcp-primitives')
        # Complete the original nine actions before any handoff. A shown
        # tab belongs to the person; each capture uses a fresh client and
        # performs no further MCP action after handing that fixture over.
        summary['capture_checks'] = {}
        for name in ['button', 'iframe-cross']:
            client = new_client('mcp-capture-' + name)
            tab = None
            shown = False
            try:
                prims.reset(name)
                snap = client('open', url=f'{prims.BASE}/{PAGES.get(name, name)}.html?task={prims.PREFIX}{name}')
                tab = prims.tab_of(snap)
                prims.CASES[name](client, snap, tab)
                client('show', tab=tab)
                shown = True
                require_window(ask)
                state = require_page_window(ask, tab)
                path = out / (name + '.png')
                metadata = picture(proc.pid, path)
                assert metadata.get('capture') == 'ScreenCaptureKit', metadata
                assert metadata['window'] == state['window'], (metadata, state)
                summary['pictures'].append({'path': str(path), 'capture': metadata})
                summary['capture_checks'][name] = {'passed': True}
            except Exception as error:
                summary['capture_checks'][name] = {'passed': False, 'error': repr(error), 'traceback': traceback.format_exc()}
            finally:
                if tab and not shown:
                    try: client('close', tab=tab)
                    except Exception: pass
                finish_client(client, 'mcp-capture-' + name)
                (out / 'summary.json').write_text(json.dumps(summary, indent=2))
        summary['passed'] = (all(check['passed'] for check in summary['checks'].values())
                             and all(check['passed'] for check in summary['capture_checks'].values()))
    finally:
        (out / 'summary.json').write_text(json.dumps(summary, indent=2))
        try:
            # The guard names why it refused (never page words); keep it in the farm log.
            lines = [l for l in (out / 'browser.log').read_text(errors='replace').splitlines() if 'agent guard refused' in l]
            print('guard refusals:', len(lines)); print('\n'.join(sorted(set(lines))[:20]))
            if not summary.get('passed'):
                tail = (out / 'browser.log').read_text(errors='replace').splitlines()[-60:]
                print('browser.log tail:'); print('\n'.join(l[:300] for l in tail))
        except OSError: pass
        for client, label in clients:
            try: finish_client(client, label)
            except Exception as error:
                summary.setdefault('cleanup_errors', []).append(repr(error))
        summary['passed'] = (summary.get('passed') is True and bool(clients)
            and len(summary['mcp_cleanup']) == len(clients)
            and all(row.get('passed') is True for row in summary['mcp_cleanup'])
            and not summary.get('cleanup_errors'))
        try:
            lifetime.finish(summary)
        except Exception as error:
            summary['passed'] = False
            summary['gui_cleanup_error'] = repr(error)
        (out / 'summary.json').write_text(json.dumps(summary, indent=2))
        for item in servers: item.shutdown(); item.server_close()
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
    print(json.dumps(summary, indent=2))
    if not summary.get('passed'): raise RuntimeError('Chromium agent acceptance failed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--prepared-app', action='store_true', help='Use the already sealed signed app without copying or signing')
    parser.add_argument('--settle-open', action='store_true', help='Diagnostic only: reread after initial navigation')
    parser.add_argument('--security', action='store_true')
    parser.add_argument('--only', help='Comma-separated existing browse primitive names; default is the original 17')
    parser.add_argument('--geometry', action='store_true', help='Also check screenshot-coordinate clicks at native CEF zoom')
    parser.add_argument('--focus', action='store_true', help='Run the independent focused-send checks without repeating the secret inventory checks')
    parser.add_argument('--url-download', action='store_true')
    args = parser.parse_args()
    run(args.app.resolve(), args.out, args.settle_open, args.security,
        args.only.split(',') if args.only is not None else None, args.geometry, args.focus, args.url_download, args.prepared_app)
