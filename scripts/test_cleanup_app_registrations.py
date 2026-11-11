#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
MODULE = ROOT / 'cleanup_app_registrations.py'
if not MODULE.exists():
    MODULE = ROOT.parent / 'lib/cleanup_app_registrations.py'


def load_cleanup_module():
    spec = importlib.util.spec_from_file_location('cleanup_apps', MODULE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cleanup = load_cleanup_module()


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / 'Product.app'
        self.app.mkdir()
        self.helper = self.app / 'Contents/Helpers/Helper.app'
        self.helper.mkdir(parents=True)
        self.other = self.root.with_name(self.root.name + '-active') / 'Product.app'
        self.records = [self.app, self.app, self.helper, self.other]
        self.commands = []
        self.live = ''
        self.failure = False
        self.addCleanup(patch.stopall)
        patch.object(cleanup.sys, 'platform', 'darwin').start()
        patch.object(cleanup, 'SETTLE_SECONDS', 0).start()
        patch.object(cleanup.subprocess, 'check_output', side_effect=self.output).start()
        patch.object(cleanup.subprocess, 'run', side_effect=self.run_command).start()
        patch.object(cleanup, 'running_executables', side_effect=lambda: [Path(self.live.strip())] if self.live else []).start()

    def output(self, command, **kwargs):
        if command[0] == '/bin/ps':
            return self.live
        return '\n------------------------------\n'.join(
            f'bundle id: app\npath: {p} (0x123)\n' for p in self.records)

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if self.failure:
            return subprocess.CompletedProcess(command, 2, '', 'denied')
        self.records.remove(Path(command[-1]))
        return subprocess.CompletedProcess(command, 0, '', '')

    def test_indented_dump_paths_are_registered(self):
        with patch.object(cleanup.subprocess, 'check_output', return_value=f'    bundle id: app\n    path: {self.app} (0x123)\n'):
            self.assertEqual(cleanup.registered_apps(), [self.app])

    def test_many_duplicates_are_drained_while_progress_continues(self):
        self.records = [self.app] * 12 + [self.other]
        cleanup.prepare(self.root)
        self.assertEqual(self.records, [self.other])

    def test_success_without_progress_is_bounded(self):
        with patch.object(cleanup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            with self.assertRaises(RuntimeError):
                cleanup.prepare(self.root)
        self.assertLessEqual(run.call_count, 18)

    def test_case_alias_cannot_hide_running_app(self):
        mixed = self.root / 'MixedCase'
        mixed.mkdir()
        alias = self.root / 'mixedcase'
        if not alias.exists():
            self.skipTest('case-sensitive volume')
        self.live = str(mixed / 'Product.app/Contents/MacOS/Product')
        with self.assertRaises(RuntimeError):
            cleanup.prepare(alias)
        self.assertEqual(self.commands, [])

    def test_delayed_registration_after_empty_dump_is_removed(self):
        self.records = [self.app]
        with patch.object(cleanup, 'registered_apps', side_effect=[[], [self.app], [], []]):
            cleanup.prepare(self.root)
        self.assertEqual(self.records, [])

    def test_nested_duplicate_and_missing_apps_leave_other_tree_alone(self):
        missing = self.root / 'Already deleted.app'
        self.records.append(missing)
        cleanup.prepare(self.root)
        self.assertEqual(self.records, [self.other])
        self.assertTrue(self.app.exists(), 'unregister must not delete builds')
        self.assertEqual(self.commands[0][-1], str(self.helper))

    def test_running_executable_with_unrelated_cwd_keeps_all_records(self):
        self.live = str(self.app / 'Contents/MacOS/Product') + '\n'
        with self.assertRaises(RuntimeError):
            cleanup.prepare(self.root)
        self.assertEqual(self.commands, [])
        self.assertEqual(len(self.records), 4)

    def test_failure_retains_files_and_reports_error(self):
        self.failure = True
        with self.assertRaises(RuntimeError):
            cleanup.prepare(self.root)
        self.assertTrue(self.app.exists())
        self.assertEqual(len(self.records), 4)

    def test_symlink_does_not_unregister_external_app(self):
        link = self.root / 'Redirect.app'
        link.symlink_to(self.other)
        self.records = [link, self.other]
        with self.assertRaises(RuntimeError):
            cleanup.prepare(self.root)
        self.assertEqual(self.commands, [])

    def test_process_inspection_failure_is_not_permission_to_clean(self):
        with patch.object(cleanup, 'running_executables', side_effect=OSError('denied')):
            with self.assertRaises(OSError):
                cleanup.prepare(self.root)
        self.assertEqual(self.commands, [])

    def test_env_overrides_lsregister_and_settle_seconds(self):
        with patch.dict(
            os.environ,
            {
                'KOE_LSREGISTER': '/custom/stub/lsregister',
                'KOE_CLEANUP_SETTLE_SECONDS': '0.125',
            },
            clear=False,
        ):
            reloaded = load_cleanup_module()
        self.assertEqual(reloaded.LSREGISTER, '/custom/stub/lsregister')
        self.assertEqual(reloaded.SETTLE_SECONDS, 0.125)

    def test_inside_detects_unicode_nfc_and_nfd_equivalence(self):
        nfc_dir = self.root / 'Caf\u00e9'
        nfd_dir = self.root / 'Cafe\u0301'
        self.assertTrue(cleanup.inside(nfc_dir / 'Koe.app', nfd_dir))
        self.assertTrue(cleanup.inside(nfd_dir / 'Koe.app', nfc_dir))

    def test_canonicalize_bundle_path_guards_dotdot_symlinks_and_on_disk_casing(self):
        caller_pwd = self.root / 'caller'
        caller_pwd.mkdir()
        fake_home = self.root / 'HomeDir'
        (fake_home / 'Applications').mkdir(parents=True)

        sym_dir = self.root / 'sym_dir'
        sym_dir.symlink_to(caller_pwd)
        with self.assertRaises(ValueError):
            cleanup.canonicalize_bundle_path(
                f'{sym_dir}/../Bypass.app', caller_pwd, fake_home, 'MACOS_INSTALL_PATH'
            )

        real_app = self.root / 'InstallDir' / 'Koe.app'
        real_app.mkdir(parents=True)
        link_app = caller_pwd / 'Link.app'
        link_app.symlink_to(real_app)
        with self.assertRaises(ValueError):
            cleanup.canonicalize_bundle_path(
                'Link.app', caller_pwd, fake_home, 'MACOS_INSTALL_PATH'
            )

        tilde_resolved = cleanup.canonicalize_bundle_path(
            '~/Applications/Koe.app', caller_pwd, fake_home, 'MACOS_INSTALL_PATH'
        )
        self.assertEqual(tilde_resolved, fake_home / 'Applications' / 'Koe.app')

        folded = self.root / 'installdir' / 'koe.app'
        if folded.exists() and folded.samefile(real_app):
            preserved = cleanup.canonicalize_bundle_path(
                str(folded), caller_pwd, fake_home, 'MACOS_INSTALL_PATH'
            )
            self.assertEqual(preserved, real_app)


if __name__ == '__main__':
    unittest.main()
