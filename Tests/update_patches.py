#!/usr/bin/env python3
"""Check update isolation, check mode and IPA discovery without reference clients."""
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'Tools'))
import update_patches as updater


class UpdatePatchesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        (self.root/'Tools').mkdir()
        self.profile = self.root/'Patches/native-tl-v1'
        self.profile.mkdir(parents=True)
        (self.profile/'patch.json').write_text('original')
        (self.root/updater.MATCHER).parent.mkdir(parents=True)
        (self.root/updater.MATCHER).write_text('original matcher')
        self.output = io.StringIO()
        self.enterContext(redirect_stdout(self.output))
        self.enterContext(redirect_stderr(self.output))

    def test_failed_generation_keeps_profiles_and_runtime_matcher(self):
        def fail(work):
            (work/'Patches/native-tl-v1/patch.json').write_text('partial')
            (work/updater.MATCHER).write_text('partial matcher')
            raise ValueError('unknown ABI')
        self.assertFalse(updater.attempt(self.root, 'Native', fail))
        self.assertEqual((self.profile/'patch.json').read_text(), 'original')
        self.assertEqual((self.root/updater.MATCHER).read_text(), 'original matcher')
        self.assertIn('unknown ABI', self.output.getvalue())

    def test_success_after_failure_exports_new_profile_and_keeps_existing(self):
        def fail(work):
            raise ValueError('failed')
        def create(work):
            profile = work/'Patches/rust-new'
            profile.mkdir()
            (profile/'patch.json').write_text('new profile')
            (profile/'bridge.bin').write_bytes(b'payload')
            return [profile.relative_to(work)]
        self.assertFalse(updater.attempt(self.root, 'failed', fail))
        self.assertTrue(updater.attempt(self.root, 'Rust', create))
        self.assertEqual((self.profile/'patch.json').read_text(), 'original')
        self.assertEqual((self.root/'Patches/rust-new/patch.json').read_text(), 'new profile')
        self.assertEqual((self.root/'Patches/rust-new/bridge.bin').read_bytes(), b'payload')

    def test_check_reports_changes_without_writing(self):
        def change(work):
            (work/'Patches/native-tl-v1/patch.json').write_text('updated')
            return [Path('Patches/native-tl-v1')]
        self.assertFalse(updater.attempt(self.root, 'Native', change, check=True))
        self.assertEqual((self.profile/'patch.json').read_text(), 'original')
        self.assertIn('generated files differ', self.output.getvalue())

    def test_check_accepts_missing_ignored_payload_without_creating_it(self):
        def rebuild(work):
            (work/'Patches/native-tl-v1/bridge.bin').write_bytes(b'payload')
            return [Path('Patches/native-tl-v1')]
        self.assertTrue(updater.attempt(self.root, 'Native', rebuild, check=True))
        self.assertFalse((self.profile/'bridge.bin').exists())

    def test_discovery_requires_explicit_choice_for_multiple_versions(self):
        old, new = self.root/'Telegram_v1.ipa', self.root/'Telegram_v2.ipa'
        old.touch()
        self.assertEqual(updater.find_ipa(self.root, 'telegram', None), old)
        new.touch()
        with self.assertRaisesRegex(ValueError, '--telegram'):
            updater.find_ipa(self.root, 'telegram', None)
        self.assertEqual(updater.find_ipa(self.root, 'telegram', new), new)
        self.assertIsNone(updater.find_ipa(self.root, 'swiftgram', None))

    def test_main_continues_after_failed_attempt_and_returns_failure(self):
        ipa = self.root/'Telegram.ipa'
        ipa.touch()
        with patch.object(sys, 'argv', ['update_patches.py', '--packages', str(self.root)]), \
                patch.dict('os.environ', {'IPATCH_ENGINE_CLI': ''}), \
                patch.object(updater, 'attempt', side_effect=[False, True]) as attempt:
            self.assertEqual(updater.main(), 1)
        self.assertEqual(attempt.call_count, 2)

    def test_engine_validation_enables_optional_feature_and_rejects_empty_plan(self):
        (self.profile/'patch.json').write_text(json.dumps({
            'components': [{'id': 'swiftgram-pro', 'default_enabled': False}]}))
        with patch.object(updater, 'run', side_effect=['', '{"plan":{"patches":[]}}']) as run:
            with self.assertRaisesRegex(ValueError, 'no binary edits'):
                updater.validate(self.root, self.profile, [Path('Swiftgram.ipa')], Path('/engine'))
        selection = json.loads((self.root/'selection.json').read_text())
        self.assertEqual(selection, {str(self.root/'profile.ipatch'): ['swiftgram-pro']})
        self.assertIn('-feature-selection', run.call_args.args[0])

    def test_subprocess_failure_includes_engine_error_and_diagnostics(self):
        result = updater.subprocess.CompletedProcess([], 1, '{"error":"ABI mismatch"}', 'Planning IPA')
        with patch.object(updater.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(ValueError, 'ABI mismatch'):
                updater.run(['/engine'], self.root)


if __name__ == '__main__':
    unittest.main()
