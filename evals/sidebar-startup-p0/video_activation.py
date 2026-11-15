#!/usr/bin/env python3
"""Isolate row 600's playing-video/app-return trigger from startup placement.

Uses exact existing apps and isolated profiles. Finder activation uses the
existing own-app bench action, with no physical input or permission changes.
An existing local video fixture and public YouTube remain separate.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import traceback
from urllib.parse import urlparse

from pair import World, Page, identity, ROOT, require_focus_contract, run_with_focus_guard

sys.path.insert(0, str(ROOT / 'evals'))

VIDEO = '''<!doctype html><meta charset=utf-8><title>Row 600 video fixture</title>
<style>body{margin:0;background:#eaf0f9;color:#162441;font:24px system-ui}
main{padding:64px 32px}video{width:800px;max-width:90vw;background:#222}</style>
<main><h1>Local video fixture: app return</h1>
<video src=/clip.mp4 autoplay muted loop playsinline controls></video>
<p>Only this tab is awake. Sidebar should remain hidden on app return.</p></main>'''
MEASURE = '''JSON.stringify((()=>{
window.__row600Nonce ||= crypto.randomUUID();
let p=document.getElementById('movie_player'),v=p?.querySelector('video')||document.querySelector('video');
return {nonce:window.__row600Nonce,url:location.href,title:document.title,
visibility:document.visibilityState,hasFocus:document.hasFocus(),
time:v?.currentTime??null,duration:v?.duration??null,paused:v?.paused??null,
ready:v?.readyState??null,source:v?.currentSrc??null,width:v?.videoWidth??0,height:v?.videoHeight??0,
muted:v?.muted??null,decoded:v?.webkitDecodedFrameCount??null,
playerState:p?.getPlayerState?.()??null,videoId:p?.getVideoData?.().video_id??null,
ad:p?.classList.contains('ad-showing')??false,
error:document.querySelector('.ytp-error-content-wrap')?.textContent||'',
captcha:!!document.querySelector('form[action*="sorry"],iframe[src*="recaptcha"]'),
mediaError:v?.error?{code:v.error.code,message:v.error.message}:null};})())'''
PLAY = '''(()=>{let p=document.getElementById('movie_player'),v=p?.querySelector('video')||document.querySelector('video');
if(!v)return false;v.muted=true;p?.mute?.();p?.playVideo?.();v.play().catch(()=>{});return true})()'''
CONSENT = '''(()=>{let b=[...document.querySelectorAll('button,[role=button]')].find(e=>
e.getBoundingClientRect().width>0&&/^(reject all|alle ablehnen|tout refuser)$/i.test(e.textContent.trim()));
if(b)b.click();return {rejected:!!b}})()'''


class VideoPage(Page):
    def do_GET(self):
        if self.path.startswith('/video'):
            body, kind = VIDEO.encode(), 'text/html; charset=utf-8'
        elif self.path == '/clip.mp4':
            body, kind = (ROOT / 'evals/player-pause/clip.mp4').read_bytes(), 'video/mp4'
        else:
            return super().do_GET()
        self.send_response(200); self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


class VideoWorld(World):
    def __init__(self, app, out, base, kind, video):
        super().__init__(app, out, base, 35 if kind == 'fixture' else 500, True, True)
        self.kind, self.video = kind, video
        session = json.loads((self.support / 'session.json').read_text())
        session['tabs'][0].update(url=video, title='Playing video trigger')
        (self.support / 'session.json').write_text(json.dumps(session))
        self.report.update(video_kind=kind, video_url=video, host=os.environ.get('WHERE'),
            macos=subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
            activation_method='Existing float.app.away activates Finder through NSRunningApplication; front activates own AppKit window. No physical Cmd-Tab.',
            profile_limitations='35 existing-clip fixture tabs or 500 public-YouTube tabs with one awake. Default extensions. Reporter 30 extensions, accounts, M1 Max and macOS 27 not matched.',
            local_fixture={'path': 'evals/player-pause/clip.mp4',
                'introduced_by_commit': 'f4d0c3260ec84638029a86b25bbde4382e1efcbc',
                'sha256': '3a26a3700d1bf63910bb87e54f17db1eb5e0c59320812c01b7e09976538a6c2d',
                'provenance': 'Existing committed native video fixture; original generation method not asserted.'})
        self.report['local_fixture']['actual_sha256'] = hashlib.sha256((ROOT / 'evals/player-pause/clip.mp4').read_bytes()).hexdigest()
        if self.report['local_fixture']['actual_sha256'] != self.report['local_fixture']['sha256']:
            raise RuntimeError('Existing clip identity changed in this snapshot')
        # Record effective product defaults; do not change auto-PiP settings.
        self.report['pip_preferences'] = {}
        for key, default in [('float.leave', True), ('float.away', False)]:
            got = subprocess.run(['defaults', 'read', self.domain, key], text=True, capture_output=True)
            self.report['pip_preferences'][key] = {'stored': got.stdout.strip() if got.returncode == 0 else None,
                                                    'effective_default_if_absent': default}
        self.save()

    def media(self):
        value = self.ask(do='eval', id=self.tab, js=MEASURE).get('value')
        return json.loads(value) if isinstance(value, str) else value or {}

    def qualify(self, phase):
        limit = time.monotonic() + (60 if self.kind == 'youtube' else 20)
        consent_tried = False
        while True:
            value = self.media()
            if value.get('captcha'):
                self.note(phase + ': captcha stops qualification', value)
                return False
            if self.kind == 'youtube' and not consent_tried:
                self.note(phase + ': public consent rejection only', self.ask(do='eval', id=self.tab, js=CONSENT))
                consent_tried = True
            self.ask(do='eval', id=self.tab, js=PLAY)
            first = self.media(); time.sleep(.65); second = self.media()
            source_ok = (urlparse(second.get('url', '')).hostname in ('www.youtube.com', 'youtube.com') and
                         second.get('videoId') == 'LXb3EKWsInQ' and second.get('playerState') == 1
                         if self.kind == 'youtube' else (second.get('source') or '').endswith('/clip.mp4'))
            valid = source_ok and not second.get('ad') and not second.get('error') and not second.get('mediaError') and \
                second.get('paused') is False and (second.get('ready') or 0) >= 2 and \
                (second.get('width') or 0) > 0 and (second.get('height') or 0) > 0 and \
                isinstance(second.get('nonce'), str) and bool(second['nonce']) and \
                first.get('nonce') == second.get('nonce') and isinstance(first.get('time'), (int, float)) and \
                isinstance(second.get('time'), (int, float)) and second['time'] > first['time'] + .1
            self.note(phase + ': playback qualification sample', {'first': first, 'second': second, 'qualified': valid})
            if valid:
                self.check(phase + ': actual playback qualified', True, second)
                return second
            if time.monotonic() >= limit:
                self.check(phase + ': actual playback qualified', False, second)
                return False
            time.sleep(.4)

    def hidden_gate(self, phase):
        start = len(self.report['checks'])
        state = self.column(phase)
        self.visibility(phase, state, False); self.native_hits(phase + ': page routes', False)
        return all(c['ok'] for c in self.report['checks'][start:])

    def pictures(self, phase):
        # Native chrome capture stays distinct from actual window/video pixels.
        self.shot(phase + '-native')
        try:
            status = json.loads(subprocess.check_output(['./farm', 'status', '--json'], text=True, timeout=90))
            capability = status.get('hosts', {}).get(os.environ['WHERE'], {})
            self.note(phase + ': current host capture capability', {k: capability.get(k) for k in ['capture', 'observed', 'online']})
            if capability.get('capture') is not True:
                raise RuntimeError('Skipped optional window capture: current farm host capture is not true')
            helper = Path.home() / '.local/state/yab-farm/capture-tools/capture-window'
            if not helper.is_file():
                raise RuntimeError('No existing authorized capture helper; no helper build requested')
            window = self.ask(do='probe')['window']
            path = self.out / (phase + '-window.png')
            curtains = []
            if os.environ['WHERE'] == 'adhd':
                curtains = [row.split(None, 1)[0] for row in subprocess.check_output(['ps', '-Ao', 'pid=,comm='], text=True).splitlines()
                            if row.strip().endswith('/blackout')]
                if not curtains: raise RuntimeError('adhd blackout is not running')
            command = [str(helper), str(self.proc.pid), str(path), str(window), *curtains]
            inspected = subprocess.run(command + ['--metadata-only'], capture_output=True, text=True, timeout=15)
            if inspected.returncode: raise RuntimeError(inspected.stderr.strip() or inspected.stdout.strip())
            metadata = json.loads(inspected.stdout)
            path.with_suffix('.occlusion.json').write_text(json.dumps(metadata, indent=2))
            # One authorized backend attempt only. No denied-TCC fallback,
            # alternative recorder, setup, or permission retry.
            captured = subprocess.run(command, capture_output=True, text=True, timeout=15)
            if captured.returncode: raise RuntimeError(captured.stderr.strip() or captured.stdout.strip())
            if not path.is_file() or path.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
                raise RuntimeError('window capture did not save a PNG')
            metadata = json.loads(captured.stdout)
            self.note(phase + ': target window capture', metadata)
            path.with_suffix('.json').write_text(json.dumps(metadata, indent=2))
        except (RuntimeError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
            if 'blackout is not' in str(error): raise
            self.report.setdefault('capture_gaps', []).append({'phase': phase, 'error': str(error)})
            self.save()

    def activation(self, phase):
        # Heal known baseline startup first. Never count a later startup
        # failure as evidence for the independent app-return trigger.
        front = self.ask(do='float', action='app', how='front', settle=.4)
        self.note(phase + ': owned app initially active', front)
        self.check(phase + ': owned app initially active', front.get('active') is True, front)
        if front.get('active') is not True:
            raise RuntimeError('owned app not initially active; trigger setup incomplete')
        self.menu('Show Sidebar'); self.menu('Hide Sidebar')
        if not self.hidden_gate(phase + ': healed hidden precondition'):
            raise RuntimeError('hidden baseline precondition failed before video/app switch')
        before = self.qualify(phase)
        if not before:
            self.report.setdefault('unqualified_phases', []).append(phase); self.save(); return
        if getattr(self, 'previous_nonce', None):
            self.check(phase + ': qualified video is a new document after Quit', before['nonce'] != self.previous_nonce, before)
            if before['nonce'] == self.previous_nonce:
                raise RuntimeError('qualified video document survived Quit; relaunch setup invalid')
        self.note(phase + ': native player band before switch', self.ask(do='band', seconds=.05))
        if not self.hidden_gate(phase + ': qualified playback hidden precondition'):
            raise RuntimeError('sidebar was not hidden immediately before app switch')
        self.pictures(phase + '-before-away')
        away = self.ask(do='float', action='app', how='away', settle=1.2)
        self.note(phase + ': app switched away', away)
        self.check(phase + ': owned app actually inactive', away.get('active') is False, away)
        if away.get('active') is not False:
            raise RuntimeError('no actual inactive transition; trigger unexercised')
        self.note(phase + ': away native placement', self.column(phase + ': away read-only state'))
        self.note(phase + ': away media', self.media())
        back = self.ask(do='float', action='app', how='front', settle=1.2)
        self.note(phase + ': app returned', back)
        self.check(phase + ': owned app actually reactivated', back.get('active') is True, back)
        if back.get('active') is not True:
            raise RuntimeError('no actual active transition; return unexercised')
        start = len(self.report['checks'])
        hidden_after = self.hidden_gate(phase + ': returned hidden before edge')
        after_a = self.media(); time.sleep(.65); after_b = self.media()
        self.note(phase + ': returned playback samples', [after_a, after_b])
        self.note(phase + ': native player band after return', self.ask(do='band', seconds=.05))
        self.check(phase + ': document nonce survives activation', after_a.get('nonce') == before['nonce'] == after_b.get('nonce'), [before, after_a, after_b])
        self.check(phase + ': playback advances after return', after_b.get('paused') is False and
                   not after_b.get('ad') and not after_b.get('mediaError') and
                   (self.kind != 'youtube' or after_b.get('videoId') == 'LXb3EKWsInQ' and after_b.get('playerState') == 1) and
                   isinstance(after_a.get('time'), (int, float)) and isinstance(after_b.get('time'), (int, float)) and
                   after_b['time'] > after_a['time'] + .1, [after_a, after_b])
        self.pictures(phase + '-returned-before-edge')
        # Separately exercise the existing synthetic edge contract.
        self.ask(do='edge', at=[650, 380], front=True, wait=1)
        self.ask(do='edge', at=[1, 380], front=True, wait=1.1)
        self.visibility(phase + ': reveal after return', self.column(phase + ': reveal'), True)
        self.ask(do='edge', at=[650, 380], front=True, wait=1)
        self.hidden_gate(phase + ': leave after return')
        self.ask(do='edge', **{'let': True})
        self.pictures(phase + '-after-edge-leave')
        self.report.setdefault('trigger_results', []).append({'phase': phase, 'qualified': True,
            'hidden_after_return': hidden_after, 'activation_checks_passed': all(c['ok'] for c in self.report['checks'][start:]),
            'nonce': before['nonce']})
        self.save()

    def run(self):
        self.previous_nonce = None
        try:
            for phase in ['launch', 'relaunch']:
                self.spawn(phase)
                tabs = self.ask(do='tabs')['tabs']; self.tab = next(t['id'] for t in tabs if t['active'])
                # The first read preserves restored state before playback or
                # the ordinary Show/Hide cycle changes native placement.
                initial = self.media(); self.note(phase + ': initial document identity', initial)
                self.activation(phase)
                self.previous_nonce = self.media().get('nonce')
                self.note(phase + ': final restore/warm count', self.ask(do='census'))
                self.quit(phase)
            self.report['harness_completed'] = True
        except Exception:
            self.report['error'] = traceback.format_exc(); print(self.report['error'], flush=True)
        finally:
            if self.proc and self.proc.poll() is None:
                self.report['forced_cleanup'] = True; self.proc.terminate(); self.proc.wait(15)
            triggers = self.report.get('trigger_results', [])
            self.report['trigger_qualified_both_lifecycles'] = len(triggers) == 2
            self.report['activation_passed'] = len(triggers) == 2 and all(r['activation_checks_passed'] for r in triggers)
            self.report['all_invariants_passed'] = self.report.get('harness_completed', False) and all(c['ok'] for c in self.report['checks'])
            self.save()
        return self.report


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--base-app', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True); parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--source-job', help='Optional exact input app job; binary identities remain authoritative')
    args = parser.parse_args(); assert os.environ.get('YAB_FARM_WORKER') == '1'
    require_focus_contract(args.out, 'video activation entry before profile or app launch')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), VideoPage)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    results = {'source_job': args.source_job, 'historical_origin_job': '93a1ef2f255c44ba',
               'input_apps': {'base': identity(args.base_app), 'candidate': identity(args.app)},
               'reuse_only': True, 'worlds': {}}
    try:
        for label, app in [('base', args.base_app), ('candidate', args.app)]:
            results['worlds'][label] = []
            for kind, url in [('fixture', base + '/video'), ('youtube', 'https://www.youtube.com/watch?v=LXb3EKWsInQ')]:
                world = VideoWorld(app, args.out / label / kind, base, kind, url)
                results['worlds'][label].append(world.run())
    finally: server.shutdown()
    results['candidate_activation_passed'] = all(r['activation_passed'] for r in results['worlds']['candidate'])
    results['candidate_all_invariants_passed'] = all(r['all_invariants_passed'] for r in results['worlds']['candidate'])
    results['harness_completed'] = all(r.get('harness_completed') for rows in results['worlds'].values() for r in rows)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'summary.json').write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')
    print('VIDEO_ACTIVATION ' + json.dumps({k:v for k,v in results.items() if k != 'worlds'}), flush=True)
    return 0 if results['candidate_activation_passed'] and results['candidate_all_invariants_passed'] and results['harness_completed'] else 1


if __name__ == '__main__': sys.exit(run_with_focus_guard(main))
