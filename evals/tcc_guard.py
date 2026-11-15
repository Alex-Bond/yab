#!/usr/bin/env python3
"""Observe unattended consent prompts without answering or dismissing them.

A late probe prompt or system dialog is reported as blocked; this observer
never signals tccd or UserNotificationCenter. Closing dialogs left up is the
farm executor's job (scripts/remote/farm_service.py, close_dialogs): it runs
from the installed runtime, not a job's snapshot, after each job and every
half minute, never on main.

Started by probe_app.launch and each farm display job, with one observer per
Mac/user. Keep the existing v2 lock so frozen older probes cannot bypass an
active safe observer. --hold-legacy-lock waits for that lock and holds it
without querying system services, for a safe rollout while jobs continue.
"""
import fcntl, json, os, re, subprocess, sys, threading, time
from pathlib import Path

PATIENCE = 3
DIALOG_PATIENCE = 8
LINGER = 120
# Deliberately retain the legacy lock name to exclude unsafe frozen guards.
VERSION = 2
LOCK = Path('/tmp') / ('yab-tcc-guard-%d-v%d.lock' % (os.getuid(), VERSION))
LOG = Path.home() / 'Library/Logs/yab-tcc-guard.log'
PREDICATE = 'process == "tccd" AND (eventMessage CONTAINS "AUTHREQ_PROMPTING" OR eventMessage CONTAINS "AUTHREQ_RESULT")'
MSG = re.compile(r'msgID=([^,\s]+)')
# UserNotificationCenter's windows on screen, by number. JXA bridges
# CoreGraphics without sending an Apple event, so it asks nobody.
DIALOGS_JS = """ObjC.import('CoreGraphics');
const rows = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)), out = [];
for (let i = 0; i < rows.count; i++) {
  const w = rows.objectAtIndex(i);
  if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerName')) === 'UserNotificationCenter') out.push(ObjC.unwrap(w.objectForKey('kCGWindowNumber')));
}
JSON.stringify(out);"""


def note(line):
    with LOG.open('a') as f: f.write(time.strftime('%Y-%m-%dT%H:%M:%S ') + line + '\n')


def probes_alive():
    rows = subprocess.run(['ps', '-Ao', 'command='], capture_output=True, text=True).stdout
    return 'yab-gui-probe-' in rows or 'farm.py _inner' in rows


def dialogs():
    try: out = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', DIALOGS_JS], capture_output=True, text=True, timeout=10).stdout
    except subprocess.TimeoutExpired: return set()
    try: return set(json.loads(out or '[]'))
    except ValueError: return set()


def notification_center():
    out = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', 'UserNotificationCenter'], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else 0


def mine(pid):
    out = subprocess.run(['ps', '-o', 'uid=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    return out == str(os.getuid())


def main():
    # --stdin: tccd's events as ndjson lines on stdin instead of the log,
    # and {"dialogs": [...], "center": pid} lines for what is on screen,
    # for evals/tcc-guard/check.py.
    test = '--stdin' in sys.argv
    hold = '--hold-legacy-lock' in sys.argv
    lock = (LOCK.with_suffix('.test') if test else LOCK).open('a')
    try: fcntl.flock(lock, fcntl.LOCK_EX | (0 if hold else fcntl.LOCK_NB))
    except BlockingIOError: return
    note('observe-only %s (pid %d)' % ('legacy lock held' if hold else 'watching', os.getpid()))
    if hold:
        while True: time.sleep(30)
    stream = subprocess.Popen(['cat'] if test else ['/usr/bin/log', 'stream', '--style', 'ndjson', '--predicate', PREDICATE],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, stdin=None if test else subprocess.DEVNULL)
    pending, guard = {}, threading.Lock()
    shown, seen, told = {'dialogs': set(), 'center': 0}, {}, set()

    def read():
        for line in stream.stdout:
            try: event = json.loads(line)
            except ValueError: continue
            if 'dialogs' in event:
                with guard: shown.update(dialogs=set(event['dialogs']), center=int(event.get('center') or 0))
                continue
            text = event.get('eventMessage', '')
            found = MSG.search(text)
            if not found: continue
            with guard:
                if 'AUTHREQ_PROMPTING' in text and 'dev.serafim.yab.probe' in text:
                    service = re.search(r'service=(\w+)', text)
                    pending[found.group(1)] = (time.monotonic(), int(event.get('processID') or 0), service.group(1) if service else '?')
                elif 'AUTHREQ_RESULT' in text:
                    pending.pop(found.group(1), None)

    threading.Thread(target=read, daemon=True).start()
    last_probe = time.monotonic()
    try:
        while True:
            time.sleep(1)
            now = time.monotonic()
            if test or probes_alive(): last_probe = now
            on_screen = None if test else dialogs()
            with guard:
                late = {k: v for k, v in pending.items() if now - v[0] >= PATIENCE}
                for key, (_, pid, service) in late.items():
                    note('BLOCKED: probe prompt for %s unanswered %d s (msgID %s, process %d); left untouched' % (service, PATIENCE, key, pid))
                    for other in [k for k, v in pending.items() if v[1] == pid]: pending.pop(other, None)
                up = shown['dialogs'] if test else on_screen
                for number in list(seen):
                    if number not in up: seen.pop(number)
                for number in up: seen.setdefault(number, now)
                stuck = [n for n, since in seen.items() if now - since >= DIALOG_PATIENCE]
                if stuck:
                    for n in set(stuck) - told: note('BLOCKED: dialog up %d s (window %s); left untouched' % (DIALOG_PATIENCE, n))
                    told.update(stuck)
                if not pending and (now - last_probe > LINGER or stream.poll() is not None): break
    finally:
        stream.terminate()
        note('done')


def start():
    """From probe_app.launch: the guard in the background, if none runs."""
    if sys.platform != 'darwin': return
    subprocess.Popen([sys.executable, '-I', str(Path(__file__).resolve())], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


if __name__ == '__main__': main()
