#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import run_mobile_e2e


ROOT = Path(__file__).resolve().parent.parent


def _minimal_fixture() -> dict:
    return {
        'generation': 1,
        'error': None,
        'playback': {
            'asset': 'sample.wav',
            'recordId': 'rec-1',
            'isPlaying': True,
            'positionMs': 500,
            'requestId': 7,
            'lanes': ['raw'],
        },
        'activeCapture': {'id': 'cap-1'},
        'liveCaption': {'text': 'hello'},
        'device': {
            'recording': True,
            'busy': True,
            'liveRecordId': 'rec-live',
            'progress': 0.0,
            'files': [{'id': 101, 'title': 'Clip', 'downloading': False}],
        },
        'workspaces': {'picker': {'canReleaseToPhone': False}},
    }


class RunMobileE2ETest(unittest.TestCase):
    def test_cli_validates_required_platform_arguments(self) -> None:
        script = str(ROOT / 'scripts' / 'run_mobile_e2e.py')
        with tempfile.TemporaryDirectory() as tmp:
            for args in (['ios', tmp], ['android', tmp]):
                with self.subTest(args=args):
                    proc = subprocess.run(
                        [sys.executable, script, *args],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(proc.returncode, 2)
                    self.assertIn('--udid', proc.stderr)
                    self.assertIn('--apk', proc.stderr)

    def test_android_run_is_self_contained_without_ios_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'repo'
            fixture_path = root / 'platforms/android/tests/fixtures/android-rich-snapshot.json'
            fixture_path.parent.mkdir(parents=True)
            fixture_path.write_text(json.dumps(_minimal_fixture()), encoding='utf-8')
            apk_path = Path(tmp) / 'app-github-debug.apk'
            apk_path.write_bytes(b'PK')
            evidence = Path(tmp) / 'evidence'

            recorded: list[tuple[list[str], dict | None]] = []

            def fake_seeder(directory: Path, *, title: str, speakers: tuple[str, ...]) -> str:
                self.assertEqual(title, 'M9Synced')
                self.assertEqual(speakers, ('Alice', 'Bob'))
                (directory / 'product-workspace.json').write_text('{"seeded": true}', encoding='utf-8')
                return 'rec-synced-102'

            def fake_runner(cmd, **kwargs):
                cmd_str = [str(part) for part in cmd]
                captured_fixture = None
                if '--fixture' in cmd_str:
                    captured_fixture = json.loads(
                        Path(cmd_str[cmd_str.index('--fixture') + 1]).read_text(encoding='utf-8')
                    )
                recorded.append((cmd_str, captured_fixture))
                self.assertTrue(kwargs.get('check'))

            run_mobile_e2e.run_e2e(
                'android',
                evidence,
                apk=apk_path,
                root=root,
                seeder=fake_seeder,
                runner=fake_runner,
            )

            self.assertFalse((root / 'platforms/ios').exists())
            self.assertEqual(len(recorded), 4)
            self.assertEqual(recorded[0][0], ['cargo', 'build', '-p', 'koe-host-api'])

            live_cmd, live_fixture = recorded[1]
            self.assertIsNone(live_fixture)
            self.assertTrue(live_cmd[0].endswith('platforms/android/verify-emulator.sh'))
            self.assertIn('--with-audio', live_cmd)
            self.assertIn(str(apk_path.resolve()), live_cmd)
            self.assertIn('--grant-permission', live_cmd)
            self.assertIn('android.permission.RECORD_AUDIO', live_cmd)
            self.assertTrue(live_cmd[live_cmd.index('--flow') + 1].endswith('e2e-design-purpose-android.yaml'))
            self.assertTrue(live_cmd[live_cmd.index('--restart-flow') + 1].endswith('design-restart.yaml'))
            self.assertEqual(Path(live_cmd[live_cmd.index('--artifacts-dir') + 1]), (evidence / 'android/live').resolve())

            for idx, phase in ((2, 'device'), (3, 'device-link')):
                cmd, fixture = recorded[idx]
                self.assertTrue(cmd[cmd.index('--flow') + 1].endswith(f'design-{phase}.yaml'))
                self.assertEqual(
                    Path(cmd[cmd.index('--artifacts-dir') + 1]),
                    (evidence / 'android' / phase).resolve(),
                )
                assert fixture is not None
                self.assertEqual(fixture['generation'], 1_000_000)
                self.assertEqual(fixture['error'], 'M9 BLE interrupted')
                self.assertIsNone(fixture['playback']['asset'])
                self.assertIsNone(fixture['activeCapture'])
                self.assertTrue(fixture['device']['files'][0]['downloading'])
                self.assertEqual(fixture['device']['files'][-1]['recordId'], 'rec-synced-102')
                self.assertTrue(fixture['workspaces']['picker']['canReleaseToPhone'])

    def test_ios_run_invokes_simulator_harness_and_refuses_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'repo'
            fixture_path = root / 'platforms/ios/Tests/Fixtures/ios-rich-snapshot.json'
            fixture_path.parent.mkdir(parents=True)
            fixture_path.write_text(json.dumps(_minimal_fixture()), encoding='utf-8')
            evidence = Path(tmp) / 'evidence'
            recorded: list[list[str]] = []

            def fake_seeder(directory: Path, **_kwargs) -> str:
                (directory / 'product-workspace.json').write_text('{}', encoding='utf-8')
                return 'rec-ios-1'

            def fake_runner(cmd, **_kwargs):
                recorded.append([str(part) for part in cmd])

            run_mobile_e2e.run_e2e(
                'ios',
                evidence,
                udid='SIM-UDID-123',
                root=root,
                seeder=fake_seeder,
                runner=fake_runner,
            )

            self.assertEqual(len(recorded), 4)
            self.assertTrue(recorded[1][0].endswith('platforms/ios/verify-simulator.sh'))
            self.assertIn('--udid', recorded[1])
            self.assertIn('SIM-UDID-123', recorded[1])
            self.assertTrue(recorded[1][recorded[1].index('--flow') + 1].endswith('e2e-design-purpose-ios.yaml'))

            with self.assertRaises(FileExistsError):
                run_mobile_e2e.run_e2e(
                    'ios',
                    evidence,
                    udid='SIM-UDID-123',
                    root=root,
                    seeder=fake_seeder,
                    runner=fake_runner,
                )

    def test_default_seeder_uses_custom_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            custom_root = Path(tmp) / 'custom-repo'
            custom_root.mkdir()
            evidence = Path(tmp) / 'evidence'
            with self.assertRaises(OSError) as ctx:
                run_mobile_e2e.run_e2e(
                    'ios',
                    evidence,
                    udid='SIM-UDID-123',
                    root=custom_root,
                    runner=lambda *_a, **_kw: None,
                )
            self.assertIn(str(custom_root / 'target/debug'), str(ctx.exception))


if __name__ == '__main__':
    unittest.main()
