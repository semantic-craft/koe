#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

from test_harness_stubs import (
    FAKE_ADB,
    FAKE_EMULATOR,
    FAKE_JAVA,
    FAKE_MAESTRO,
    read_calls,
    write_exec,
)


ROOT = Path(__file__).resolve().parent.parent
ANDROID_DIR = ROOT / 'platforms' / 'android'
GRADLE_APP_DIR = ANDROID_DIR / 'gradle-app' / 'app'
VERIFY_SCRIPT = ANDROID_DIR / 'verify-emulator.sh'
SMOKE_SCRIPT = ANDROID_DIR / 'smoke.sh'
CANONICAL_FIXTURE = ANDROID_DIR / 'tests' / 'fixtures' / 'android-rich-snapshot.json'
TEST_RESOURCE_FIXTURE = GRADLE_APP_DIR / 'src' / 'test' / 'resources' / 'android-rich-snapshot.json'
MAESTRO_DIR = ANDROID_DIR / 'tests' / 'maestro'

FAKE_VERIFY_EMULATOR = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

log_path = os.environ.get('FAKE_SMOKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['verify-emulator', *sys.argv[1:]]) + '\\n')

for i, arg in enumerate(sys.argv[1:]):
    if arg == '--artifacts-dir' and i + 2 < len(sys.argv):
        out = Path(sys.argv[i + 2])
        out.mkdir(parents=True, exist_ok=True)
        (out / 'screen.png').write_bytes(b'\\x89PNG\\r\\n\\x1a\\n')
        (out / 'trace.json').write_text(json.dumps({'outcome': 'pass', 'host_intent_trace': []}), encoding='utf-8')

sys.exit(int(os.environ.get('FAKE_VERIFY_EXIT', '0')))
'''


class AndroidAppHarnessContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        self.java_home = self.root / 'jdk'
        self.write_exec('jdk/bin/java', FAKE_JAVA)
        self.adb_bin = self.write_exec('bin/adb', FAKE_ADB)
        self.emulator_bin = self.write_exec('bin/emulator', FAKE_EMULATOR)
        self.maestro_bin = self.write_exec('bin/maestro', FAKE_MAESTRO)
        self.fake_apk = self.root / 'app-github-debug.apk'
        self.fake_apk.write_bytes(b'PK\x03\x04FAKEAPK')
        self.fake_flow = self.root / 'flow.yaml'
        self.fake_flow.write_text('appId: com.semanticcraft.koe\n---\n- assertVisible: "模式选择"\n', encoding='utf-8')
        self.fake_fixture = self.root / 'fixture.json'
        self.fake_fixture.write_text('{"version": 2, "generation": 42}\n', encoding='utf-8')
        self.call_log = self.root / 'calls.jsonl'
        self.sandbox_root = self.root / 'sandbox'

    def write_exec(self, rel, content):
        return write_exec(self.root, rel, content)

    def read_calls(self, path=None):
        return read_calls(path or self.call_log)

    def verify_env(self, **extra):
        env = dict(
            os.environ,
            JAVA_HOME=str(self.java_home),
            KOE_ADB_BIN=str(self.adb_bin),
            KOE_EMULATOR_BIN=str(self.emulator_bin),
            KOE_MAESTRO_BIN=str(self.maestro_bin),
            KOE_EMU_SHUTDOWN_TIMEOUT='2',
            KOE_TRACE_WAIT_TIMEOUT='2',
            KOE_TRACE_POLL_INTERVAL='0.05',
            FAKE_CALL_LOG=str(self.call_log),
            FAKE_SANDBOX_ROOT=str(self.sandbox_root),
            FAKE_HOST_TRACE_JSON=json.dumps([
                {
                    'kind': 'snapshot',
                    'name': 'snapshot',
                    'generation': 1,
                    'section': 'today',
                    'hasError': False,
                    'timestampEpochMs': 1763596800000,
                },
                {
                    'kind': 'event',
                    'name': 'sync_app_metadata',
                    'generation': 2,
                    'section': 'today',
                    'hasError': False,
                    'timestampEpochMs': 1763596800100,
                },
            ]),
        )
        env.update(extra)
        return env

    def test_manifest_bridge_and_canonical_fixture_contracts(self):
        android_ns = '{http://schemas.android.com/apk/res/android}'
        tools_ns = '{http://schemas.android.com/tools}'
        play_manifest = ET.parse(GRADLE_APP_DIR / 'src' / 'play' / 'AndroidManifest.xml').getroot()
        removed_perms = [
            el.attrib.get(f'{android_ns}name')
            for el in play_manifest.findall('uses-permission')
            if el.attrib.get(f'{tools_ns}node') == 'remove'
        ]
        self.assertIn('android.permission.REQUEST_INSTALL_PACKAGES', removed_perms)

        bridge_files = list(ANDROID_DIR.rglob('KoeNativeBridge.java'))
        self.assertEqual(
            bridge_files,
            [GRADLE_APP_DIR / 'src' / 'main' / 'java' / 'com' / 'semanticcraft' / 'koe' / 'bridge' / 'KoeNativeBridge.java'],
            f'KoeNativeBridge.java must exist as a single source of truth, found: {bridge_files}',
        )

        self.assertTrue(CANONICAL_FIXTURE.is_file(), f'missing canonical fixture: {CANONICAL_FIXTURE}')
        self.assertTrue(TEST_RESOURCE_FIXTURE.is_file(), f'missing test resource fixture: {TEST_RESOURCE_FIXTURE}')
        canonical_data = json.loads(CANONICAL_FIXTURE.read_text(encoding='utf-8'))
        resource_data = json.loads(TEST_RESOURCE_FIXTURE.read_text(encoding='utf-8'))
        self.assertEqual(canonical_data, resource_data, 'canonical and test resource fixtures must stay in sync')
        self.assertEqual(canonical_data['platform']['id'], 'android')
        self.assertEqual(canonical_data['platform']['hostDisplayName'], 'Android')
        self.assertEqual(canonical_data['platform']['nativeSpeechLabel'], 'Android 本机')
        self.assertFalse(canonical_data['platform']['supportsSystemAudio'])

        for flow_name in ('smoke-android-live.yaml', 'smoke-android-fixture.yaml', 'fail-probe-android.yaml'):
            flow_path = MAESTRO_DIR / flow_name
            self.assertTrue(flow_path.is_file(), f'missing Maestro flow: {flow_path}')
            flow_text = flow_path.read_text(encoding='utf-8')
            self.assertIn('appId: com.semanticcraft.koe', flow_text)

    def test_verify_emulator_installs_apk_launches_app_and_embeds_host_intent_trace(self):
        artifacts_dir = self.root / 'live-artifacts'
        result = subprocess.run(
            [
                str(VERIFY_SCRIPT),
                '--reuse-serial', 'emulator-5580',
                '--apk', str(self.fake_apk),
                '--app-package', 'com.semanticcraft.koe',
                '--app-activity', 'com.semanticcraft.koe/.MainActivity',
                '--launch-app',
                '--flow', str(self.fake_flow),
                '--keep-artifacts',
                '--artifacts-dir', str(artifacts_dir),
            ],
            cwd=ROOT,
            env=self.verify_env(FAKE_MAESTRO_EXIT='0'),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        calls = self.read_calls()
        install_idx = next(
            (i for i, c in enumerate(calls) if c[0] == 'adb' and 'install' in c and '-r' in c),
            None,
        )
        am_start_idx = next(
            (i for i, c in enumerate(calls) if c[0] == 'adb' and 'shell' in c and 'am start -W -S' in ' '.join(c)),
            None,
        )
        maestro_idx = next((i for i, c in enumerate(calls) if c[0] == 'maestro'), None)
        self.assertIsNotNone(install_idx, f'expected adb install -r call in {calls}')
        self.assertIsNotNone(am_start_idx, f'expected am start -W -S call in {calls}')
        self.assertIsNotNone(maestro_idx, f'expected maestro call in {calls}')
        self.assertLess(install_idx, am_start_idx)
        self.assertLess(am_start_idx, maestro_idx)

        am_cmd = ' '.join(calls[am_start_idx])
        self.assertIn('--es koe_workspace', am_cmd)
        self.assertNotIn('koe_snapshot_fixture', am_cmd)

        trace = json.loads((artifacts_dir / 'trace.json').read_text(encoding='utf-8'))
        self.assertEqual(trace['outcome'], 'pass')
        self.assertIsInstance(trace['host_intent_trace'], list)
        self.assertEqual(len(trace['host_intent_trace']), 2)
        self.assertEqual(trace['host_intent_trace'][1]['name'], 'sync_app_metadata')

    def test_verify_emulator_stages_fixture_and_handles_red_and_expect_failure(self):
        fixture_artifacts = self.root / 'fixture-artifacts'
        res_fixture = subprocess.run(
            [
                str(VERIFY_SCRIPT),
                '--reuse-serial', 'emulator-5580',
                '--app-package', 'com.semanticcraft.koe',
                '--fixture', str(self.fake_fixture),
                '--launch-app',
                '--flow', str(self.fake_flow),
                '--keep-artifacts',
                '--artifacts-dir', str(fixture_artifacts),
            ],
            cwd=ROOT,
            env=self.verify_env(FAKE_MAESTRO_EXIT='0'),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(res_fixture.returncode, 0, res_fixture.stderr)
        staged = self.sandbox_root / 'app_sandbox' / 'com.semanticcraft.koe' / 'files' / 'koe-active-fixture.json'
        self.assertTrue(staged.is_file(), 'fixture must be staged into files/koe-active-fixture.json via run-as')
        self.assertEqual(json.loads(staged.read_text(encoding='utf-8'))['generation'], 42)
        calls = self.read_calls()
        am_calls = [' '.join(c) for c in calls if c[0] == 'adb' and 'am start -W -S' in ' '.join(c)]
        self.assertEqual(len(am_calls), 1)
        self.assertIn('--es koe_snapshot_fixture koe-active-fixture.json', am_calls[0])

        fail_artifacts = self.root / 'fail-artifacts'
        res_red = subprocess.run(
            [
                str(VERIFY_SCRIPT),
                '--reuse-serial', 'emulator-5580',
                '--app-package', 'com.semanticcraft.koe',
                '--launch-app',
                '--flow', str(self.fake_flow),
                '--artifacts-dir', str(fail_artifacts),
            ],
            cwd=ROOT,
            env=self.verify_env(FAKE_MAESTRO_EXIT='1'),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(res_red.returncode, 1)
        red_trace = json.loads((fail_artifacts / 'trace.json').read_text(encoding='utf-8'))
        self.assertEqual(red_trace['outcome'], 'fail')
        self.assertIsInstance(red_trace['host_intent_trace'], list)

        expect_artifacts = self.root / 'expect-fail-artifacts'
        res_expect = subprocess.run(
            [
                str(VERIFY_SCRIPT),
                '--reuse-serial', 'emulator-5580',
                '--app-package', 'com.semanticcraft.koe',
                '--launch-app',
                '--flow', str(self.fake_flow),
                '--expect-failure',
                '--artifacts-dir', str(expect_artifacts),
            ],
            cwd=ROOT,
            env=self.verify_env(FAKE_MAESTRO_EXIT='1'),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(res_expect.returncode, 0, res_expect.stderr)
        expect_trace = json.loads((expect_artifacts / 'trace.json').read_text(encoding='utf-8'))
        self.assertEqual(expect_trace['outcome'], 'expected_failure')
        self.assertIsInstance(expect_trace['host_intent_trace'], list)

        bad_launch = subprocess.run(
            [str(VERIFY_SCRIPT), '--launch-app', '--flow', str(self.fake_flow)],
            cwd=ROOT,
            env=self.verify_env(),
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(bad_launch.returncode, 2)

    def test_smoke_script_arguments_and_stubbed_orchestration(self):
        self.assertTrue(SMOKE_SCRIPT.is_file(), f'missing smoke script: {SMOKE_SCRIPT}')
        help_res = subprocess.run(
            [str(SMOKE_SCRIPT), '--help'],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(help_res.returncode, 0, help_res.stderr)
        self.assertIn('--with-fail-probe', help_res.stdout)

        bad_arg = subprocess.run(
            [str(SMOKE_SCRIPT), '--unknown-flag'],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(bad_arg.returncode, 2)

        bad_avd = subprocess.run(
            [str(SMOKE_SCRIPT), '--avd', 'pixel_personal', '--skip-native', '--skip-gradle'],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertNotEqual(bad_avd.returncode, 0)

        fake_verify = self.write_exec('bin/verify-emulator.sh', FAKE_VERIFY_EMULATOR)
        smoke_log = self.root / 'smoke-calls.jsonl'
        smoke_artifacts = self.root / 'smoke-artifacts'
        env = dict(
            os.environ,
            KOE_VERIFY_EMULATOR_BIN=str(fake_verify),
            KOE_ANDROID_APK=str(self.fake_apk),
            FAKE_SMOKE_CALL_LOG=str(smoke_log),
        )
        res = subprocess.run(
            [
                str(SMOKE_SCRIPT),
                '--skip-native',
                '--skip-gradle',
                '--keep-artifacts',
                '--with-fail-probe',
                '--avd', 'koe-test-api35',
                '--port', '5582',
                '--artifacts-dir', str(smoke_artifacts),
            ],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.read_calls(smoke_log)
        self.assertEqual(len(calls), 3, f'expected live + fixture + fail-probe invocations, got: {calls}')

        live_call, fixture_call, fail_call = calls
        self.assertIn('--launch-app', live_call)
        self.assertIn('com.semanticcraft.koe', live_call)
        self.assertTrue(any(arg.endswith('smoke-android-live.yaml') for arg in live_call))
        self.assertNotIn('--fixture', live_call)
        self.assertIn('--grant-permission', live_call)
        self.assertIn('android.permission.RECORD_AUDIO', live_call)
        self.assertIn('android.permission.POST_NOTIFICATIONS', live_call)

        self.assertIn('--launch-app', fixture_call)
        self.assertIn('--fixture', fixture_call)
        self.assertTrue(any(arg.endswith('smoke-android-fixture.yaml') for arg in fixture_call))

        self.assertIn('--expect-failure', fail_call)
        self.assertTrue(any(arg.endswith('fail-probe-android.yaml') for arg in fail_call))

    def test_verify_emulator_grants_permissions_and_rejects_invalid_values(self):
        artifacts_dir = self.root / 'grant-artifacts'
        res = subprocess.run(
            [
                str(VERIFY_SCRIPT),
                '--reuse-serial', 'emulator-5580',
                '--apk', str(self.fake_apk),
                '--app-package', 'com.semanticcraft.koe',
                '--grant-permission', 'android.permission.RECORD_AUDIO',
                '--grant-permission', 'android.permission.POST_NOTIFICATIONS',
                '--launch-app',
                '--flow', str(self.fake_flow),
                '--artifacts-dir', str(artifacts_dir),
            ],
            cwd=ROOT,
            env=self.verify_env(FAKE_MAESTRO_EXIT='0'),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(res.returncode, 0, res.stderr)

        calls = self.read_calls()
        install_idx = next(
            (i for i, c in enumerate(calls) if c[0] == 'adb' and 'install' in c and '-r' in c),
            None,
        )
        grant_record_idx = next(
            (
                i
                for i, c in enumerate(calls)
                if c[0] == 'adb'
                and 'shell' in c
                and 'pm grant com.semanticcraft.koe android.permission.RECORD_AUDIO' in ' '.join(c)
            ),
            None,
        )
        grant_notif_idx = next(
            (
                i
                for i, c in enumerate(calls)
                if c[0] == 'adb'
                and 'shell' in c
                and 'pm grant com.semanticcraft.koe android.permission.POST_NOTIFICATIONS' in ' '.join(c)
            ),
            None,
        )
        am_start_idx = next(
            (i for i, c in enumerate(calls) if c[0] == 'adb' and 'shell' in c and 'am start -W -S' in ' '.join(c)),
            None,
        )
        self.assertIsNotNone(install_idx)
        self.assertIsNotNone(grant_record_idx, f'expected RECORD_AUDIO pm grant in {calls}')
        self.assertIsNotNone(grant_notif_idx, f'expected POST_NOTIFICATIONS pm grant in {calls}')
        self.assertIsNotNone(am_start_idx)
        self.assertLess(install_idx, grant_record_idx)
        self.assertLess(grant_record_idx, am_start_idx)
        self.assertLess(grant_notif_idx, am_start_idx)

        bad_perm = subprocess.run(
            [
                str(VERIFY_SCRIPT),
                '--reuse-serial', 'emulator-5580',
                '--app-package', 'com.semanticcraft.koe',
                '--grant-permission', 'android.permission.RECORD_AUDIO;rm -rf /',
                '--flow', str(self.fake_flow),
            ],
            cwd=ROOT,
            env=self.verify_env(),
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertNotEqual(bad_perm.returncode, 0)

        missing_pkg = subprocess.run(
            [
                str(VERIFY_SCRIPT),
                '--reuse-serial', 'emulator-5580',
                '--grant-permission', 'android.permission.RECORD_AUDIO',
                '--flow', str(self.fake_flow),
            ],
            cwd=ROOT,
            env=self.verify_env(),
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(missing_pkg.returncode, 2)


if __name__ == '__main__':
    unittest.main()
