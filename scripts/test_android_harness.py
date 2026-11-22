#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import unittest


from test_harness_stubs import (
    FAKE_ADB,
    FAKE_EMULATOR,
    FAKE_JAVA,
    FAKE_MAESTRO,
    FAKE_SLIM,
    read_calls,
    write_exec,
)

ROOT = Path(__file__).resolve().parent.parent
ANDROID_DIR = ROOT / 'platforms' / 'android'
VERIFY_SCRIPT = ANDROID_DIR / 'verify-emulator.sh'
INSTALL_SCRIPT = ANDROID_DIR / 'install-sdk-packages.sh'
FAIL_PROBE_FLOW = ANDROID_DIR / 'tests' / 'maestro' / 'fail-probe.yaml'
SMOKE_FLOW = ANDROID_DIR / 'tests' / 'maestro' / 'smoke-system-settings.yaml'

FAKE_SDKMANAGER = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['sdkmanager', *sys.argv[1:]]) + '\\n')

sdk_root = None
packages = []
is_licenses = False
for arg in sys.argv[1:]:
    if arg.startswith('--sdk_root='):
        sdk_root = Path(arg.split('=', 1)[1])
    elif arg == '--licenses':
        is_licenses = True
    elif not arg.startswith('-'):
        packages.append(arg)

if is_licenses:
    sys.exit(0)

state_file = Path(os.environ['FAKE_SDKMANAGER_ATTEMPTS'])
attempts = int(state_file.read_text(encoding='utf-8')) if state_file.exists() else 0
attempts += 1
state_file.write_text(str(attempts), encoding='utf-8')

fail_times = int(os.environ.get('FAKE_SDKMANAGER_FAIL_TIMES', '0'))
if attempts <= fail_times:
    (sdk_root / '.temp').mkdir(parents=True, exist_ok=True)
    (sdk_root / '.temp' / 'partial.zip').write_text('partial', encoding='utf-8')
    (sdk_root / '.downloadIntermediates').mkdir(parents=True, exist_ok=True)
    (sdk_root / '.downloadIntermediates' / 'chunk').write_text('chunk', encoding='utf-8')
    sys.stderr.write('simulated transient download failure\\n')
    sys.exit(1)

for pkg in packages:
    pkg_dir = sdk_root.joinpath(*pkg.split(';'))
    pkg_dir.mkdir(parents=True, exist_ok=True)
    (pkg_dir / 'package.xml').write_text('<package/>\\n', encoding='utf-8')
    if pkg == 'platform-tools':
        adb = pkg_dir / 'adb'
        adb.write_text('#!/bin/sh\\nexit 0\\n', encoding='utf-8')
        adb.chmod(0o755)
    elif pkg == 'emulator':
        emu = pkg_dir / 'emulator'
        emu.write_text('#!/bin/sh\\nexit 0\\n', encoding='utf-8')
        emu.chmod(0o755)
    elif pkg.startswith('cmdline-tools;'):
        bin_dir = pkg_dir / 'bin'
        bin_dir.mkdir(parents=True, exist_ok=True)
        template = Path(os.environ['FAKE_SDK_AVDMANAGER_TEMPLATE']).read_text(encoding='utf-8')
        avd_bin = bin_dir / 'avdmanager'
        avd_bin.write_text(template, encoding='utf-8')
        avd_bin.chmod(0o755)
        sdk_bin = bin_dir / 'sdkmanager'
        sdk_bin.write_text('#!/bin/sh\\nexit 0\\n', encoding='utf-8')
        sdk_bin.chmod(0o755)
    elif pkg.startswith('platforms;'):
        (pkg_dir / 'android.jar').write_bytes(b'PK')
    else:
        (pkg_dir / 'source.properties').write_text('Pkg.Revision=1\\n', encoding='utf-8')

sys.exit(0)
'''

FAKE_AVDMANAGER = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['avdmanager', *sys.argv[1:]]) + '\\n')

args = sys.argv[1:]
name = args[args.index('-n') + 1]
avd_home = Path(os.environ['ANDROID_AVD_HOME'])
avd_dir = avd_home / f'{name}.avd'
avd_dir.mkdir(parents=True, exist_ok=True)
(avd_home / f'{name}.ini').write_text(f'path={avd_dir}\\n', encoding='utf-8')
(avd_dir / 'config.ini').write_text(
    'avd.ini.encoding=UTF-8\\nhw.audioInput=yes\\nhw.cpu.ncore=4\\n',
    encoding='utf-8',
)
sys.exit(0)
'''


def pid_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_until(predicate, timeout=5.0, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


class AndroidHarnessTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        self.java_home = self.root / 'jdk'
        self.adb_bin = self.write_exec('bin/adb', FAKE_ADB)
        self.emulator_bin = self.write_exec('bin/emulator', FAKE_EMULATOR)
        self.maestro_bin = self.write_exec('bin/maestro', FAKE_MAESTRO)
        self.sdkmanager_bin = self.write_exec('bin/sdkmanager', FAKE_SDKMANAGER)
        self.avdmanager_bin = self.write_exec('bin/avdmanager', FAKE_AVDMANAGER)
        self.write_exec('jdk/bin/java', FAKE_JAVA)

        self.call_log = self.root / 'calls.jsonl'
        self.emu_pid_file = self.root / 'emu.pid'
        self.emu_child_pid_file = self.root / 'emu_child.pid'
        self.sdk_root = self.root / 'sdk'
        self.avd_home = self.root / 'avd'

    def write_exec(self, rel, content):
        return write_exec(self.root, rel, content)

    def base_env(self, **extra):
        env = dict(
            os.environ,
            JAVA_HOME=str(self.java_home),
            ANDROID_SDK_ROOT=str(self.sdk_root),
            ANDROID_HOME=str(self.sdk_root),
            ANDROID_AVD_HOME=str(self.avd_home),
            KOE_ADB_BIN=str(self.adb_bin),
            KOE_EMULATOR_BIN=str(self.emulator_bin),
            KOE_MAESTRO_BIN=str(self.maestro_bin),
            KOE_SDKMANAGER_BIN=str(self.sdkmanager_bin),
            KOE_AVDMANAGER_BIN=str(self.avdmanager_bin),
            KOE_EMU_SHUTDOWN_TIMEOUT='3',
            FAKE_CALL_LOG=str(self.call_log),
            FAKE_EMU_PID_FILE=str(self.emu_pid_file),
            FAKE_EMU_CHILD_PID_FILE=str(self.emu_child_pid_file),
            FAKE_DEVICE_TS='2026-11-20 07:30:00.000',
        )
        env.update(extra)
        return env

    def read_calls(self):
        return read_calls(self.call_log)

    def run_verify(self, args, **env_extra):
        return subprocess.run(
            [str(VERIFY_SCRIPT), *args],
            cwd=ROOT,
            env=self.base_env(**env_extra),
            capture_output=True,
            text=True,
            timeout=30,
        )

    def assert_emulator_reaped(self):
        self.assertTrue(self.emu_pid_file.exists(), 'fake emulator did not write its PID file')
        emu_pid = int(self.emu_pid_file.read_text(encoding='utf-8').strip())
        self.assertTrue(wait_until(lambda: not pid_exists(emu_pid), timeout=3.0),
                        f'fake emulator PID {emu_pid} leaked after exit')
        if self.emu_child_pid_file.exists():
            child_pid = int(self.emu_child_pid_file.read_text(encoding='utf-8').strip())
            self.assertTrue(wait_until(lambda: not pid_exists(child_pid), timeout=3.0),
                            f'fake emulator child PID {child_pid} leaked after exit')

    def fake_slim(self):
        return self.write_exec('bin/fake-slim', FAKE_SLIM)

    def test_slim_snapshot_cold_boot_audio_and_workspace(self):
        snapshot = self.avd_home / 'koe-test-api35.avd/snapshots/avdslim_clean'
        tool = self.fake_slim()
        artifacts = self.root / 'evidence'
        args = ['--slim', '--with-audio', '--flow', str(SMOKE_FLOW), '--workspace', 'journeys',
                '--launch-app', '--app-package', 'com.semanticcraft.koe', '--artifacts-dir', str(artifacts)]
        source = snapshot.parents[1]
        source.mkdir(parents=True)
        config = source / 'config.ini'
        original = 'fastboot.forceColdBoot=yes\nhw.audioInput=no\nhw.audioOutput=no\n'
        config.write_text(original)
        (self.avd_home / 'koe-test-api35.ini').write_text(f'path={source}\n')
        observation = self.root / 'launch-config.json'
        cases = [
            ('fresh', False, None, False),
            ('fresh-slim', True, None, False),
            ('silent-golden', True, ('no', 'no'), False),
            ('input-only', True, ('yes', 'no'), False),
            ('output-only', True, ('no', 'yes'), False),
            ('audio-golden', True, ('YeS', 'YES'), True),
            ('emulator-boolean-golden', True, ('true', 'true'), True),
        ]
        for label, slim, audio, load_snapshot in cases:
            with self.subTest(label=label):
                if audio:
                    snapshot.mkdir(parents=True, exist_ok=True)
                    saved = (f'hw.ramSize = 1536\nfastboot.forceColdBoot = true\n'
                             f'HW.audioInput = {audio[0]}\nhw.audioOutput={audio[1]}\n')
                    (snapshot / 'hardware.ini').write_text(saved)
                    (snapshot / 'ram.bin').write_bytes(b'golden')
                self.call_log.unlink(missing_ok=True)
                result = self.run_verify(args if slim else args[1:], KOE_AVDSLIM_BIN=str(tool),
                                         FAKE_AVD_OBSERVATION=str(observation))
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.read_calls()
                emulator = next(c for c in calls if c[0] == 'emulator')
                self.assertNotIn('-no-audio', emulator)
                self.assertIn('-no-snapshot-save', emulator)
                if load_snapshot:
                    self.assertEqual(emulator[emulator.index('-snapshot') + 1], 'avdslim_clean')
                    self.assertNotIn('-no-snapshot-load', emulator)
                    self.assertIn('-force-snapshot-load', emulator)
                    self.assertIn('-lowram', emulator)
                    self.assertEqual(emulator[emulator.index('-memory') + 1], '1536')
                else:
                    self.assertIn('-no-snapshot-load', emulator)
                    self.assertNotIn('-snapshot', emulator)
                    self.assertNotIn('-force-snapshot-load', emulator)
                path, effective = json.loads(observation.read_text())
                self.assertNotEqual(Path(path), config)
                for key in ('hw.audioInput', 'hw.audioOutput'):
                    self.assertRegex(effective, rf'(?m)^{re.escape(key)}\s*=\s*yes$')
                self.assertEqual(config.read_text(), original)
                if audio:
                    self.assertEqual((snapshot / 'hardware.ini').read_text(), saved)
                    self.assertEqual((snapshot / 'ram.bin').read_bytes(), b'golden')
                self.assertEqual(list(self.avd_home.glob('.koe-verify-*')), [])
                self.assertEqual(emulator[emulator.index('-gpu') + 1], 'host' if slim else 'auto')
                self.assertEqual(['slim', 'on', 'emulator-5580', '--skip=bluetooth', '--no-anim'] in calls,
                                 slim and not load_snapshot)
                self.assertEqual(['slim', 'measure', 'emulator-5580'] in calls, slim)
                self.assertTrue(any('koe_workspace verify-workspaces/journeys' in c[-1] for c in calls if c[0] == 'adb'))
        self.assertIn('256', (artifacts / 'avdslim-metrics.txt').read_text())

    def test_restart_flow_reopens_same_workspace_on_same_running_emulator(self):
        restart = self.root / 'restart.yaml'
        restart.write_text('appId: com.semanticcraft.koe\n---\n- assertVisible: survivor\n')
        app_files = self.root / 'app-files'
        app_files.mkdir()
        live = self.root / 'evidence/live'
        result = self.run_verify(['--flow', str(SMOKE_FLOW), '--restart-flow', str(restart), '--launch-app',
                                  '--app-package', 'com.semanticcraft.koe', '--workspace', 'persistent/session',
                                  '--artifacts-dir', str(live)], FAKE_APP_FILES=str(app_files))
        self.assertEqual(result.returncode, 0, result.stderr)
        for phase in (live, live.parent / 'restart'):
            self.assertEqual(json.loads((phase / 'workspace/product-workspace.json').read_text())['records'],
                             [{'id': 'survivor'}])
        self.assertEqual(sum(c[0] == 'emulator' for c in self.read_calls()), 1)
        stops = [c for c in self.read_calls() if c[0] == 'adb' and c[-1] == 'am force-stop com.semanticcraft.koe']
        self.assertEqual(len(stops), 2)
        self.assert_emulator_reaped()

    def test_missing_avdslim_preserves_explicit_gpu(self):
        result = self.run_verify(['--slim', '--self-check', '--gpu', 'auto',
                                  '--artifacts-dir', str(self.root / 'slim')],
                                 KOE_AVDSLIM_BIN=str(self.root / 'missing'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('avdslim', result.stderr)
        emulator = next(c for c in self.read_calls() if c[0] == 'emulator')
        self.assertEqual(emulator[emulator.index('-gpu') + 1], 'auto')
        self.assertIn('-no-audio', emulator)

    def test_rejects_non_test_avd_before_launching_emulator(self):
        result = self.run_verify(['--avd', 'pixel_personal', '--self-check'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('koe-test-api', result.stderr)
        self.assertFalse(self.emu_pid_file.exists())
        self.assertEqual(self.read_calls(), [])

    def test_rejects_reuse_serial_for_physical_device_or_non_test_avd(self):
        phys = self.run_verify(['--reuse-serial', '3A151FDJH00123', '--self-check'])
        self.assertNotEqual(phys.returncode, 0)
        self.assertIn('physical', phys.stderr.lower())
        self.assertEqual(self.read_calls(), [])

        non_test = self.run_verify(
            ['--reuse-serial', 'emulator-5554', '--self-check'],
            FAKE_EMU_AVD_NAME='pixel_personal',
        )
        self.assertNotEqual(non_test.returncode, 0)
        self.assertIn('pixel_personal', non_test.stderr)
        calls = self.read_calls()
        self.assertFalse(any(c[0] in ('emulator', 'maestro') for c in calls))

        self.call_log.unlink()
        ok = self.run_verify(
            ['--reuse-serial', 'emulator-5580', '--self-check'],
            FAKE_EMU_AVD_NAME='koe-test-api35',
        )
        self.assertEqual(ok.returncode, 0, ok.stderr)
        ok_calls = self.read_calls()
        self.assertFalse(any(c[0] == 'emulator' for c in ok_calls))
        self.assertFalse(any(c[0] == 'adb' and c[-2:] == ['emu', 'kill'] for c in ok_calls))

    def test_failing_flow_collects_four_artifacts_without_logcat_clear_and_cleans_emulator(self):
        artifacts_dir = self.root / 'fail-artifacts'
        result = self.run_verify(
            ['--flow', str(FAIL_PROBE_FLOW), '--artifacts-dir', str(artifacts_dir)],
            FAKE_MAESTRO_EXIT='1',
        )
        self.assertEqual(result.returncode, 1)
        self.assert_emulator_reaped()

        screen = artifacts_dir / 'screen.png'
        hierarchy = artifacts_dir / 'window_hierarchy.xml'
        logcat = artifacts_dir / 'logcat.txt'
        trace_file = artifacts_dir / 'trace.json'

        for artifact in (screen, hierarchy, logcat, trace_file):
            self.assertTrue(artifact.exists() and artifact.stat().st_size > 0, f'missing/empty {artifact.name}')

        self.assertTrue(screen.read_bytes().startswith(b'\x89PNG'))
        self.assertIn('<hierarchy', hierarchy.read_text(encoding='utf-8'))
        logcat_text = logcat.read_text(encoding='utf-8')
        self.assertIn('fake main log entry', logcat_text)
        self.assertIn('fake crash entry', logcat_text)

        trace = json.loads(trace_file.read_text(encoding='utf-8'))
        self.assertEqual(trace['platform'], 'android')
        self.assertEqual(trace['avd'], 'koe-test-api35')
        self.assertEqual(trace['serial'], 'emulator-5580')
        self.assertEqual(trace['api_level'], '35')
        self.assertEqual(trace['abi'], 'arm64-v8a')
        self.assertEqual(trace['flow_exit_code'], 1)
        self.assertEqual(trace['outcome'], 'fail')
        self.assertIsNone(trace['host_intent_trace'])
        self.assertEqual(
            set(trace['artifacts'].keys()),
            {'screen', 'hierarchy', 'log', 'maestro_debug_dir'},
        )
        self.assertFalse((artifacts_dir / 'koe-trace.json').exists())

        adb_logcat_calls = [c for c in self.read_calls() if c[0] == 'adb' and 'logcat' in c]
        self.assertGreaterEqual(len(adb_logcat_calls), 2)
        for call in adb_logcat_calls:
            self.assertNotIn('-c', call, f'destructive logcat -c called: {call}')
            self.assertIn('-d', call)
            self.assertIn('-T', call)
            t_idx = call.index('-T')
            self.assertEqual(call[t_idx + 1], '2026-11-20 07:30:00.000')

    def test_expect_failure_contract(self):
        artifacts_dir = self.root / 'expect-fail-artifacts'
        expected = self.run_verify(
            ['--flow', str(FAIL_PROBE_FLOW), '--expect-failure', '--artifacts-dir', str(artifacts_dir)],
            FAKE_MAESTRO_EXIT='1',
        )
        self.assertEqual(expected.returncode, 0, expected.stderr)
        self.assert_emulator_reaped()
        for name in ('screen.png', 'window_hierarchy.xml', 'logcat.txt', 'trace.json'):
            path = artifacts_dir / name
            self.assertTrue(path.exists() and path.stat().st_size > 0, f'missing/empty {name}')
        trace = json.loads((artifacts_dir / 'trace.json').read_text(encoding='utf-8'))
        self.assertEqual(trace['outcome'], 'expected_failure')
        self.assertEqual(trace['flow_exit_code'], 1)

        unexpected_dir = self.root / 'unexpected-pass-artifacts'
        unexpected = self.run_verify(
            ['--flow', str(SMOKE_FLOW), '--expect-failure', '--artifacts-dir', str(unexpected_dir)],
            FAKE_MAESTRO_EXIT='0',
        )
        self.assertNotEqual(unexpected.returncode, 0)
        self.assert_emulator_reaped()

    def test_self_check_keep_artifacts_records_device_props_and_cleans_emulator(self):
        artifacts_dir = self.root / 'pass-artifacts'
        result = self.run_verify(
            ['--self-check', '--keep-artifacts', '--artifacts-dir', str(artifacts_dir)],
            FAKE_MAESTRO_EXIT='0',
            FAKE_API_LEVEL='35',
            FAKE_ABI='arm64-v8a',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_emulator_reaped()

        trace = json.loads((artifacts_dir / 'trace.json').read_text(encoding='utf-8'))
        self.assertEqual(trace['outcome'], 'pass')
        self.assertEqual(trace['flow_exit_code'], 0)
        self.assertEqual(trace['api_level'], '35')
        self.assertEqual(trace['abi'], 'arm64-v8a')
        self.assertTrue(trace['flow'].endswith('platforms/android/tests/maestro/smoke-system-settings.yaml'))

        maestro_calls = [c for c in self.read_calls() if c[0] == 'maestro']
        self.assertEqual(len(maestro_calls), 1)
        self.assertIn('--udid', maestro_calls[0])
        self.assertEqual(
            maestro_calls[0][-1],
            {
                'MAESTRO_CLI_NO_ANALYTICS': '1',
                'MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED': 'true',
            },
        )

    def test_uiautomator_dump_retries_after_transient_accessibility_busy_error(self):
        artifacts_dir = self.root / 'retry-dump-artifacts'
        dump_attempts = self.root / 'dump.attempts'
        result = self.run_verify(
            ['--flow', str(FAIL_PROBE_FLOW), '--expect-failure', '--artifacts-dir', str(artifacts_dir)],
            FAKE_MAESTRO_EXIT='1',
            FAKE_UIAUTOMATOR_FAIL_TIMES='2',
            FAKE_UIAUTOMATOR_ATTEMPTS=str(dump_attempts),
            KOE_UIAUTOMATOR_RETRY_DELAY='0.05',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_emulator_reaped()
        self.assertEqual(dump_attempts.read_text(encoding='utf-8').strip(), '3')
        self.assertIn('<hierarchy', (artifacts_dir / 'window_hierarchy.xml').read_text(encoding='utf-8'))

    def test_back_to_back_runs_wait_for_adb_deregistration_after_teardown(self):
        stale_file = self.root / 'stale_adb.state'
        first = self.run_verify(
            ['--self-check', '--port', '5580'],
            FAKE_MAESTRO_EXIT='0',
            FAKE_ADB_STALE_FILE=str(stale_file),
            FAKE_ADB_STALE_POLLS='3',
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assert_emulator_reaped()

        second = self.run_verify(
            ['--self-check', '--port', '5580'],
            FAKE_MAESTRO_EXIT='0',
            FAKE_ADB_STALE_FILE=str(stale_file),
            FAKE_ADB_STALE_POLLS='0',
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assert_emulator_reaped()

    def test_sigterm_mid_boot_terminates_emulator_process_group(self):
        with subprocess.Popen(
            [str(VERIFY_SCRIPT), '--self-check', '--boot-timeout', '60'],
            cwd=ROOT,
            env=self.base_env(FAKE_ADB_STATE='offline', FAKE_EMU_KILL_FAIL='1'),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as proc:
            try:
                self.assertTrue(
                    wait_until(
                        lambda: self.emu_pid_file.exists() and self.emu_child_pid_file.exists(),
                        timeout=5.0,
                    ),
                    'fake emulator did not start mid-boot',
                )
                emu_pid = int(self.emu_pid_file.read_text(encoding='utf-8').strip())
                child_pid = int(self.emu_child_pid_file.read_text(encoding='utf-8').strip())
                self.assertTrue(pid_exists(emu_pid))
                self.assertTrue(pid_exists(child_pid))

                proc.send_signal(signal.SIGTERM)
                exit_code = proc.wait(timeout=10)
                self.assertNotEqual(exit_code, 0)
                self.assertTrue(wait_until(lambda: not pid_exists(emu_pid), timeout=3.0),
                                f'emulator PID {emu_pid} survived SIGTERM')
                self.assertTrue(wait_until(lambda: not pid_exists(child_pid), timeout=3.0),
                                f'emulator child PID {child_pid} survived SIGTERM')
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)

    def test_install_sdk_packages_check_only_retry_and_idempotent_avd_config(self):
        attempts_file = self.root / 'sdkmanager.attempts'
        fake_brew_prefix = self.root / 'fake-brew'
        broken_brew_dir = self.root / 'fallback-bin'
        self.write_exec(
            'fallback-bin/brew',
            f'#!/bin/sh\nprintf "%s\\n" "{fake_brew_prefix}"\n',
        )
        broken_brew_avd = self.write_exec(
            'fake-brew/share/android-commandlinetools/cmdline-tools/latest/bin/avdmanager',
            '#!/usr/bin/env python3\nimport sys\nsys.stderr.write("Valid system image paths are: null\\n")\nsys.exit(1)\n',
        )
        env = self.base_env(
            KOE_ANDROID_API='35',
            KOE_ANDROID_ABI='arm64-v8a',
            FAKE_SDKMANAGER_ATTEMPTS=str(attempts_file),
            FAKE_SDKMANAGER_FAIL_TIMES='1',
            FAKE_SDK_AVDMANAGER_TEMPLATE=str(self.avdmanager_bin),
            PATH=f'{broken_brew_dir}{os.pathsep}{os.environ["PATH"]}',
        )
        env.pop('KOE_AVDMANAGER_BIN', None)
        self.assertTrue(broken_brew_avd.exists())

        check_missing = subprocess.run(
            [str(INSTALL_SCRIPT), '--check-only'],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertNotEqual(check_missing.returncode, 0)
        self.assertIn('package:cmdline-tools;latest', check_missing.stderr)
        self.assertEqual(self.read_calls(), [])

        first_install = subprocess.run(
            [str(INSTALL_SCRIPT)],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(first_install.returncode, 0, first_install.stderr)
        self.assertEqual(attempts_file.read_text(encoding='utf-8').strip(), '2')
        self.assertFalse((self.sdk_root / '.temp').exists())
        self.assertFalse((self.sdk_root / '.downloadIntermediates').exists())
        self.assertTrue((self.sdk_root / 'cmdline-tools' / 'latest' / 'bin' / 'avdmanager').is_file())

        config_path = self.avd_home / 'koe-test-api35.avd' / 'config.ini'
        config_text = config_path.read_text(encoding='utf-8')
        for prop in ('hw.audioInput=no', 'hw.audioOutput=no', 'hw.ramSize=3072', 'disk.dataPartition.size=4096M'):
            self.assertIn(prop, config_text)
        self.assertEqual(config_text.count('hw.audioInput='), 1)

        self.call_log.unlink()
        second_install = subprocess.run(
            [str(INSTALL_SCRIPT)],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(second_install.returncode, 0, second_install.stderr)
        self.assertEqual(self.read_calls(), [])
        self.assertEqual(config_path.read_text(encoding='utf-8'), config_text)

        check_ready = subprocess.run(
            [str(INSTALL_SCRIPT), '--check-only'],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(check_ready.returncode, 0, check_ready.stderr)


if __name__ == '__main__':
    unittest.main()
