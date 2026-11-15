#!/usr/bin/env python3
"""Contract checks for the owner-run script, without a browser or credentials."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('drm_services', Path(__file__).with_name('services.py'))
services = importlib.util.module_from_spec(spec)
spec.loader.exec_module(services)
TAB = '223b1951-e726-4921-99fe-15ef3a19e4e6'


class AcceptanceContract(unittest.TestCase):
    def exercise(self, *, progress=True, selected=TAB, host='open.spotify.com', tab_ref=TAB):
        engine = 'webKit'
        choice = 'webKit'
        calls = []
        samples = 0

        def exchange(sock, request, **kwargs):
            nonlocal engine, choice, samples
            calls.append(request)
            if request.get('op') == 'site-engine':
                choice = request.get('choice', choice)
                engine = 'chromium' if choice == 'chromium' else 'webKit'
                return {'choice': choice, 'tab': TAB, 'engine': engine}
            if request.get('op') == 'script':
                samples += 1
                return {'value': [{'index': 0, 'time': 5 + (samples * 5 if progress else 0),
                                   'paused': False, 'ended': False, 'ready': 4, 'error': None}]}
            return {'tab': selected, 'engine': engine, 'url': 'https://' + host + '/private?secret=do-not-save',
                    'title': 'Private account name', 'loading': False, 'context': 10, 'window': 42}

        with tempfile.TemporaryDirectory() as folder:
            args = SimpleNamespace(out=Path(folder), socket=Path('/tmp/fake.sock'), tab=tab_ref,
                                   service='spotify', timeout=1, seconds=5, capture_pid=None)
            with patch.object(services.yab_socket, 'exchange', side_effect=exchange), \
                    patch('builtins.input', return_value=''), patch.object(services.time, 'sleep'):
                status = services.run(args)
            saved = (Path(folder) / 'summary.json').read_text()
            self.assertNotIn('do-not-save', saved)
            self.assertNotIn('Private account name', saved)
            return status, json.loads(saved), calls

    def test_real_media_advances_and_original_preference_restores(self):
        status, report, calls = self.exercise()
        self.assertEqual(status, 0)
        self.assertEqual(report['restored_choice'], 'webKit')
        self.assertEqual([c['choice'] for c in calls if 'choice' in c], ['chromium', 'recommended', 'webKit'])
        self.assertTrue(report['checks']['playing_advances'])

    def test_bench_short_id_locks_to_full_uuid_before_mutating(self):
        status, _, calls = self.exercise(tab_ref=TAB[:8])
        self.assertEqual(status, 0)
        self.assertEqual(calls[0]['id'], TAB[:8])
        self.assertTrue(all(c['id'] == TAB for c in calls if 'choice' in c))

    def test_stalled_media_is_unverified_and_preference_restores(self):
        status, report, _ = self.exercise(progress=False)
        self.assertEqual(status, 1)
        self.assertFalse(report['ok'])
        self.assertEqual(report['restored_choice'], 'webKit')

    def test_wrong_uuid_cannot_mutate_the_fallback_active_tab(self):
        status, _, calls = self.exercise(selected='another-tab')
        self.assertEqual(status, 1)
        self.assertFalse(any('choice' in c for c in calls))

    def test_non_player_host_cannot_mutate_preferences(self):
        status, _, calls = self.exercise(host='accounts.spotify.com')
        self.assertEqual(status, 1)
        self.assertFalse(any('choice' in c for c in calls))

    def test_media_must_keep_identity_and_be_healthy_and_unpaused(self):
        before = {'index': 0, 'time': 2, 'paused': False, 'ended': False, 'ready': 4, 'error': None}
        after = before | {'time': 7}
        self.assertTrue(services.playback_advanced([before], [after], 5))
        for change in [{'paused': True}, {'ended': True}, {'ready': 1}, {'error': 3}, {'time': 2.1}, {'index': 1}]:
            self.assertFalse(services.playback_advanced([before], [after | change], 5))
        self.assertFalse(services.playback_advanced([], [], 5))


if __name__ == '__main__':
    unittest.main()
