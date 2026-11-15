#!/usr/bin/env python3
"""Exercise real overlapping git patches on disposable source trees."""
import contextlib
import difflib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    'owncef_apply_series', Path(__file__).with_name('apply-series.py'))
series = importlib.util.module_from_spec(spec)
spec.loader.exec_module(series)


def patch_text(before, after, name='config.cc'):
    return ''.join(difflib.unified_diff(
        before.splitlines(True), after.splitlines(True),
        fromfile='a/' + name if before else '/dev/null',
        tofile='b/' + name if after else '/dev/null'))


class ApplySeriesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='owncef-series-test-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.source, self.patches = root / 'source', root / 'patches'
        self.source.mkdir()
        self.patches.mkdir()
        self.base = ''.join('line %d\n' % i for i in range(12))
        self.first = self.base.replace('line 3\n', 'first value\n')
        self.second = self.base.replace('line 3\n', 'second value\n')
        self.file = self.source / 'config.cc'
        self.file.write_text(self.base)
        self.a = self.patches / '0001-first.patch'
        self.b = self.patches / '0002-overlap.patch'
        self.a.write_text(patch_text(self.base, self.first))
        self.b.write_text(patch_text(self.first, self.second))

    def apply(self, check=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return series.apply_series(self.source, self.patches, check)

    def git_apply(self, patch, reverse=False):
        command = ['git', '-C', str(self.source), 'apply']
        if reverse:
            command.append('--reverse')
        subprocess.run([*command, str(patch)], check=True, capture_output=True)

    def ledger(self):
        return json.loads((self.source / series.LEDGER).read_text())['patches']

    def test_fresh_apply_and_unchanged_retry_with_overlapping_hunks(self):
        self.assertEqual(self.apply()['appliedPrefix'], 0)
        self.assertEqual(self.file.read_text(), self.second)
        before = self.file.stat().st_mtime_ns
        self.assertEqual(self.apply()['appliedPrefix'], 2)
        self.assertEqual(self.file.stat().st_mtime_ns, before)
        self.assertEqual(len(self.ledger()), 2)

    def test_check_only_never_writes_source_or_ledger(self):
        plan = self.apply(check=True)
        self.assertEqual(len(plan['missing']), 2)
        self.assertEqual(self.file.read_text(), self.base)
        self.assertFalse((self.source / series.LEDGER).exists())

    def test_legacy_prefix_and_unrelated_user_edits_survive(self):
        self.git_apply(self.a)
        self.file.write_text(self.first + 'parallel user edit\n')
        other = self.source / 'other.cc'
        other.write_text('uncommitted user work\n')
        self.assertEqual(self.apply()['appliedPrefix'], 1)
        self.assertEqual(self.file.read_text(), self.second + 'parallel user edit\n')
        self.assertEqual(other.read_text(), 'uncommitted user work\n')

    def test_interruption_after_apply_before_ledger_recovers(self):
        suffix = self.b.read_text()
        self.b.unlink()
        self.apply()
        self.b.write_text(suffix)
        self.git_apply(self.b)
        self.assertEqual(len(self.ledger()), 1)
        self.assertEqual(self.apply()['appliedPrefix'], 2)
        self.assertEqual(len(self.ledger()), 2)

    def test_changed_previously_applied_patch_is_rejected(self):
        self.apply()
        saved = (self.source / series.LEDGER).read_bytes()
        self.a.write_text(patch_text(self.base, self.base.replace('line 3', 'changed')))
        with self.assertRaisesRegex(ValueError, 'changed, removed or reordered'):
            self.apply()
        self.assertEqual(self.file.read_text(), self.second)
        self.assertEqual((self.source / series.LEDGER).read_bytes(), saved)

    def test_owned_hunk_edited_after_apply_is_not_overwritten(self):
        self.apply()
        self.file.write_text(self.second.replace('second value', 'user value'))
        saved = self.file.read_bytes()
        with self.assertRaisesRegex(ValueError, 'complete applied prefix'):
            self.apply()
        self.assertEqual(self.file.read_bytes(), saved)

    def test_source_cannot_retreat_behind_its_ledger(self):
        self.apply()
        self.git_apply(self.b, reverse=True)
        with self.assertRaisesRegex(ValueError, 'complete applied prefix'):
            self.apply()
        self.assertEqual(self.file.read_text(), self.first)
        self.assertEqual(len(self.ledger()), 2)

    def test_created_file_then_modified_file_retries(self):
        self.a.write_text(patch_text('', 'first\n', 'new.h'))
        self.b.write_text(patch_text('first\n', 'second\n', 'new.h'))
        self.apply()
        self.assertEqual((self.source / 'new.h').read_text(), 'second\n')
        self.assertEqual(self.apply()['appliedPrefix'], 2)
        self.assertEqual(self.file.read_text(), self.base)

    def test_partial_multi_file_patch_is_rejected_without_live_changes(self):
        other = self.source / 'other.cc'
        other.write_text(self.base)
        self.a.write_text(patch_text(self.base, self.first) +
                          patch_text(self.base, self.first, 'other.cc'))
        self.file.write_text(self.first)
        with self.assertRaisesRegex(ValueError, 'complete applied prefix'):
            self.apply()
        self.assertEqual(self.file.read_text(), self.first)
        self.assertEqual(other.read_text(), self.base)
        self.assertFalse((self.source / series.LEDGER).exists())

    def test_paths_cannot_escape_or_change_git_metadata(self):
        for name in ('../outside', '.git/config', 'dir/../../outside'):
            with self.subTest(name=name):
                self.a.write_text(patch_text(self.base, self.first, name))
                with self.assertRaisesRegex(ValueError, 'Unsafe patch path'):
                    self.apply()
                self.assertEqual(self.file.read_text(), self.base)

    def test_source_symlink_is_rejected_without_following_it(self):
        outside = self.source.parent / 'outside.cc'
        outside.write_text(self.base)
        self.file.unlink()
        self.file.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.apply()
        self.assertTrue(self.file.is_symlink())
        self.assertEqual(outside.read_text(), self.base)


if __name__ == '__main__':
    unittest.main(verbosity=2)
