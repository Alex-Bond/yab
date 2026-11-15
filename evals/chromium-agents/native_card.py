"""Native AskCard continuation with fresh post-answer secret checks."""
import concurrent.futures
import json
import os
import Quartz
import ApplicationServices as AX
import time
from probe_capture import picture
from agent_launch import require_page_window


def run(m, ask, out, prims, tab, snap, pid):
    checks = {}
    def check(name, condition):
        checks[name] = {'passed': bool(condition)}
        (out / 'native-card-checks.json').write_text(json.dumps(checks, indent=2))
        assert condition, name
    def wait(predicate, seconds=10):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = predicate()
            if value: return value
            time.sleep(.05)
        raise TimeoutError('Native AskCard did not appear')
    def card():
        return ask(do='chromium', id=tab, op='nav-dialog')['asks']
    def answer_card(code, label):
        # Real keyboard input targets only the exact owned app PID. Never
        # request a grant or post into the person's Mac/global HID stream.
        assert os.environ.get('WHERE') in ('adhd', 'm4', 'renderer-2')
        assert os.environ.get('YAB_FARM_HOST') != 'main'
        check(label + '-input-permitted', AX.AXIsProcessTrusted() and Quartz.CGPreflightPostEventAccess())
        ask(do='front')
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            Quartz.CGEventSetFlags(event, 0)
            Quartz.CGEventPostToPid(pid, event)
            time.sleep(.04)
        wait(lambda: not card())
        check(label + '-native-card-answered', True)
    ask(do='select', id=tab)
    state = require_page_window(ask, tab)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(m, 'click', tab=tab, ref=prims.ref(snap, r'button "Archive"'))
        shown = wait(card)
        check('native-confirm-origin-message', shown[0]['kind'] == 'confirm' and shown[0]['host'] == '127.0.0.1' and shown[0]['message'] == 'Archive this note?')
        try:
            got = pending.result(timeout=5)
            refused = False
        except AssertionError as error:
            got = str(error)
            refused = 'waiting for the person' in got
        check('native-modal-static-refusal', refused and 'Archive this note' not in got)
        (out / 'native-confirm-held-reply.txt').write_text(got)
        try:
            m('snapshot', tab=tab)
            denied = False
        except AssertionError as error:
            text = str(error)
            denied = 'waiting for the person' in text and 'Archive this note' not in text
        check('modal-snapshot-static-refusal', denied)
        # Let the existing card's entrance settle before visual acceptance.
        time.sleep(.6)
        path = out / 'native-confirm-card.png'
        metadata = picture(pid, path, window_id=state['window'])
        check('native-confirm-sck', metadata.get('capture') == 'ScreenCaptureKit')
        (out / 'native-card-capture.json').write_text(json.dumps(metadata, indent=2))
        # Return takes the existing person's card through its real key path.
        answer_card(36, 'confirm-return')
        check('confirm-page-resumed', prims.settle('dialog', 'archived').get('archived') is True)
        # Native answer delivery is asynchronous. Keep the original visible
        # result assertion, polling fresh guarded full-page snapshots until
        # it arrives. The default interactive-only tree omits this static p.
        snapshots = []
        def resumed():
            got = m('snapshot', tab=tab, interactive=False)
            snapshots.append(got)
            (out / 'native-confirm-snapshots.json').write_text(json.dumps(snapshots, indent=2))
            return got if 'Archived' in got else None
        got = wait(resumed, seconds=5)
        (out / 'native-confirm-reply.txt').write_text(got)
        check('confirm-resumed-guarded-reply', 'Archived' in got)
        check('confirm-card-settled', card() == [])
        # A secret introduced by the click before confirm must still block the
        # completed tool. Answering the native card grants no agent access.
        canary = 'SYNTHETIC_MODAL_PRIVATE_CANARY'
        ask(do='chromium', id=tab, op='script', body="document.body.innerHTML='<button>Continue</button>';document.querySelector('button').onclick=()=>{document.body.insertAdjacentHTML('beforeend','<h1>Recovery phrase</h1><input aria-label=Seed_phrase value=" + canary + ">');confirm('Native continuation security fixture');};return true")
        snap = m('snapshot', tab=tab)
        pending = pool.submit(m, 'click', tab=tab, ref=prims.ref(snap, r'button "Continue"'))
        wait(card)
        try:
            got = pending.result(timeout=5)
            refused = False
        except AssertionError as error:
            got = str(error)
            refused = 'waiting for the person' in got
        check('secret-modal-static-refusal', refused and canary not in got and 'Native continuation security fixture' not in got)
        answer_card(53, 'secret-escape')
        try:
            got = m('snapshot', tab=tab)
            refused = False
        except AssertionError as error:
            got = str(error)
            refused = 'protected' in got.lower()
        (out / 'native-secret-reply.txt').write_text(got)
        check('secret-after-native-answer-refused', refused and canary not in got)
        check('secret-card-settled', card() == [])
    return checks
