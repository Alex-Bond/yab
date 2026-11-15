#!/usr/bin/env python3
"""Bounded regression controls on an exact previously built app pair.

No product hooks, physical pointer, performance budget, or updater claim.
Generated fixture profiles and all ownership receipts stay in farm output.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

from pair import World, Page, identity, require_focus_contract, run_with_focus_guard


class Controls(World):
    def settled(self, name):
        state = self.column(name)
        requested = not state['shut'] or state['peek']
        self.visibility(name, state, requested)
        return state

    def choose(self, title):
        reply = self.ask(do='app-menu', menu='View', press=title)
        self.note('actual menu ' + title, reply)
        if not reply.get('pressed'):
            raise RuntimeError('missing enabled View action ' + title)

    def geometry(self, phase):
        # The ordinary actual Show/Hide cycle removes the known baseline
        # startup mismatch before the independent native geometry controls.
        if self.hidden:
            self.menu('Show Sidebar'); self.menu('Hide Sidebar')
        for size in [(960, 680), (1260, 800), (1180, 780)]:
            reply = self.ask(do='window', frame=[40, 40, *size], wait=.3)
            self.note(phase + ': native resize', reply)
            self.settled(phase + ': resized ' + str(size))
            self.shot(phase + '-resize-' + str(size[0]))
        # Existing bench UI action calls NSWindow.toggleFullScreen; the
        # generated probe's View menu has no native fullscreen item.
        self.note(phase + ': modeled native fullscreen request', self.ask(do='ui', fullscreen=True))
        deadline = time.monotonic() + 12
        while True:
            state = self.column(phase + ': entering fullscreen')
            if state.get('full'): break
            if time.monotonic() >= deadline: raise RuntimeError('native fullscreen did not enter')
            time.sleep(.1)
        time.sleep(.8)
        self.settled(phase + ': full screen resting'); self.shot(phase + '-fullscreen')
        self.note(phase + ': modeled native fullscreen exit request', self.ask(do='ui', fullscreen=False))
        deadline = time.monotonic() + 12
        while True:
            state = self.column(phase + ': leaving fullscreen')
            if not state.get('full'): break
            if time.monotonic() >= deadline: raise RuntimeError('native fullscreen did not exit')
            time.sleep(.1)
        time.sleep(.8)
        self.settled(phase + ': fullscreen returned'); self.shot(phase + '-returned')

    def film(self, name, action, interrupt):
        folder = self.out / name
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(self.ask, do='film', action=action, path=str(folder), seconds=1.1,
                                 width=380, side=self.flank, presentation=True, scale=1)
            time.sleep(.06)
            interrupt()
            reply = future.result(timeout=20)
        self.note('presentation film ' + name, reply)
        frames = reply.get('frames', [])
        self.check(name + ': presentation frames saved', len(frames) >= 3 and
                   all(Path(row['file']).is_file() for row in frames), reply)

    def motion(self, phase):
        def reverse():
            state = self.column(phase + ': hide interrupted')
            self.check(phase + ': actual hide requested before reversal', state.get('shut') is True, state)
            self.choose('Show Sidebar')
        self.film(phase + '-hide-reverse', 'column', reverse)
        self.settled(phase + ': reversed resting'); self.shot(phase + '-reversed')
        initial = self.ask(do='spaces'); self.note('spaces before control', initial)
        home = next(row['name'] for row in initial['spaces'] if row['current'])
        self.ask(do='space', on=True, new='Startup control')
        self.ask(do='open', url=self.base + '/pager-control', plain=True)
        self.ask(do='space', to=home); time.sleep(.6)
        def during_pager():
            before = self.ask(do='pager'); self.note('pager before hide', before)
            self.check(phase + ': pager actually active before hide', before.get('active') is True, before)
            self.choose('Hide Sidebar')
            after = self.ask(do='pager'); self.note('pager after hide', after)
            self.check(phase + ': hide settles pager and host mask', after.get('active') is False and
                       after.get('masked') is False, after)
            time.sleep(.05)
            self.choose('Show Sidebar')
        self.film(phase + '-space-hide-show', 'space-step', during_pager)
        self.settled(phase + ': space interruption resting')
        self.native_hits(phase + ': space interruption hits', True)
        self.shot(phase + '-space-returned')

    def exercise(self, phase):
        if self.mode == 'geometry': self.geometry(phase)
        else: self.motion(phase)

    def run(self):
        # Motion creates a second space; startup/relaunch counts remain the
        # separate pair proof's responsibility. Geometry changes no tabs.
        if self.mode == 'geometry': return super().run()
        try:
            self.spawn('launch'); self.exercise('launch'); self.quit('launch')
            self.report['harness_completed'] = True
        except Exception:
            import traceback
            self.report['error'] = traceback.format_exc(); print(self.report['error'], flush=True)
        finally:
            if self.proc and self.proc.poll() is None:
                self.report['forced_cleanup'] = True; self.proc.terminate(); self.proc.wait(15)
            self.report['all_invariants_passed'] = self.report.get('harness_completed', False) and all(c['ok'] for c in self.report['checks'])
            self.save()
        return self.report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-app', required=True, type=Path)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--mode', required=True, choices=['geometry', 'motion'])
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--source-job', help='Optional exact input app job; binary identities remain authoritative')
    args = parser.parse_args()
    assert os.environ.get('YAB_FARM_WORKER') == '1'
    require_focus_contract(args.out, 'sidebar motion/fullscreen controls entry')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    address = f'http://127.0.0.1:{server.server_port}'
    results = {'mode': args.mode, 'reuse_only': True, 'source_job': args.source_job,
               'historical_origin_job': '93a1ef2f255c44ba',
               'input_apps': {'base': identity(args.base_app), 'candidate': identity(args.app)},
               'limits': 'Internal menu/native-window actions and app-drawn films; physical input, reporter profile and updater unverified.',
               'worlds': {'base': [], 'candidate': []}}
    if args.mode == 'geometry':
        results['fullscreen_action'] = 'Existing bench ui.fullscreen invokes native NSWindow.toggleFullScreen; no physical keys or menu claim.'
    try:
        for label, app in [('base', args.base_app), ('candidate', args.app)]:
            configurations = [(True, False, 'right'), (False, True, 'right'),
                              (True, True, 'left'), (False, False, 'left')] if args.mode == 'geometry' else [(False, True, 'left'), (False, True, 'right')]
            for hidden, glass, flank in configurations:
                world = Controls(app, args.out / label / f'{flank}-{int(hidden)}-{int(glass)}', address, 35, hidden, glass, flank)
                world.mode = args.mode; world.base = address
                results['worlds'][label].append(world.run())
    finally:
        server.shutdown()
    results['harness_completed'] = all(row.get('harness_completed') for rows in results['worlds'].values() for row in rows)
    results['candidate_passed'] = all(row['all_invariants_passed'] for row in results['worlds']['candidate'])
    results['baseline_failures'] = [{'world': row['world'], 'failures': [c['name'] for c in row['checks'] if not c['ok']]}
                                    for row in results['worlds']['base']]
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    return 0 if results['harness_completed'] and results['candidate_passed'] else 1


if __name__ == '__main__': sys.exit(run_with_focus_guard(main))
