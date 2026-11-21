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


ROOT = Path(__file__).resolve().parent.parent
ANDROID_DIR = ROOT / 'platforms' / 'android'
VERIFY_SCRIPT = ANDROID_DIR / 'verify-emulator.sh'
INSTALL_SCRIPT = ANDROID_DIR / 'install-sdk-packages.sh'
FAIL_PROBE_FLOW = ANDROID_DIR / 'tests' / 'maestro' / 'fail-probe.yaml'
SMOKE_FLOW = ANDROID_DIR / 'tests' / 'maestro' / 'smoke-system-settings.yaml'

FAKE_JAVA = '''#!/usr/bin/env python3
import sys
sys.stderr.write('openjdk version "17.0.10"\\n')
sys.exit(0)
'''

FAKE_EMULATOR = '''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path

log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['emulator', *sys.argv[1:]]) + '\\n')

child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
pid_file = os.environ.get('FAKE_EMU_PID_FILE')
if pid_file:
    Path(pid_file).write_text(str(os.getpid()), encoding='utf-8')
child_pid_file = os.environ.get('FAKE_EMU_CHILD_PID_FILE')
if child_pid_file:
    Path(child_pid_file).write_text(str(child.pid), encoding='utf-8')

def _stop(signum, _frame):
    try:
        child.terminate()
    except OSError:
        pass
    sys.exit(0)

signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)

while True:
    time.sleep(0.1)
'''

FAKE_ADB = '''#!/usr/bin/env python3
import json, os, shlex, signal, sys
from pathlib import Path

args = sys.argv[1:]
log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['adb', *args]) + '\\n')

if args == ['devices']:
    print('List of devices attached')
    extra = os.environ.get('FAKE_ADB_DEVICES', '')
    if extra:
        print(extra)
    stale_file = os.environ.get('FAKE_ADB_STALE_FILE')
    if stale_file and Path(stale_file).exists():
        parts = Path(stale_file).read_text(encoding='utf-8').strip().split()
        if len(parts) == 2 and int(parts[1]) > 0:
            stale_serial, remaining = parts[0], int(parts[1])
            print(f'{stale_serial}\\toffline')
            Path(stale_file).write_text(f'{stale_serial} {remaining - 1}\\n', encoding='utf-8')
    sys.exit(0)

serial = None
rest = args
if len(args) >= 2 and args[0] == '-s':
    serial = args[1]
    rest = args[2:]

if rest == ['get-state']:
    state = os.environ.get('FAKE_ADB_STATE', 'device')
    if state == 'offline':
        sys.stderr.write('error: device offline\\n')
        sys.exit(1)
    print(state)
    sys.exit(0)

if rest == ['emu', 'avd', 'name']:
    avd = os.environ.get('FAKE_EMU_AVD_NAME', 'koe-test-api35')
    if avd == '__FAIL__':
        sys.stderr.write('error: not an emulator\\n')
        sys.exit(1)
    print(f'{avd}\\r')
    print('OK\\r')
    sys.exit(0)

if rest == ['emu', 'kill']:
    if os.environ.get('FAKE_EMU_KILL_FAIL') == '1':
        sys.stderr.write('error: emulator console unreachable\\n')
        sys.exit(1)
    pid_file = os.environ.get('FAKE_EMU_PID_FILE')
    if pid_file and Path(pid_file).exists():
        pid = int(Path(pid_file).read_text(encoding='utf-8').strip())
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    stale_file = os.environ.get('FAKE_ADB_STALE_FILE')
    stale_polls = int(os.environ.get('FAKE_ADB_STALE_POLLS', '0'))
    if stale_file and stale_polls > 0 and serial:
        Path(stale_file).write_text(f'{serial} {stale_polls}\\n', encoding='utf-8')
    print('OK: killing emulator, bye bye')
    sys.exit(0)

if rest and rest[0] == 'shell':
    # Real adb shell joins arguments with spaces and evaluates them under remote sh -c.
    tokens = shlex.split(' '.join(rest[1:]))
    if len(tokens) == 2 and tokens[0] == 'getprop':
        prop = tokens[1]
        props = {
            'sys.boot_completed': os.environ.get('FAKE_BOOT_COMPLETED', '1'),
            'ro.build.version.sdk': os.environ.get('FAKE_API_LEVEL', '35'),
            'ro.product.cpu.abi': os.environ.get('FAKE_ABI', 'arm64-v8a'),
        }
        print(props.get(prop, '') + '\\r')
        sys.exit(0)

    if tokens and tokens[0] == 'date':
        if len(tokens) != 2 or not tokens[1].startswith('+'):
            sys.stderr.write(f'date: bad date {tokens[1:]}\\n')
            sys.exit(1)
        print(os.environ.get('FAKE_DEVICE_TS', '2026-11-20 07:30:00.000') + '\\r')
        sys.exit(0)

    if len(tokens) == 3 and tokens[:2] == ['uiautomator', 'dump']:
        fail_times = int(os.environ.get('FAKE_UIAUTOMATOR_FAIL_TIMES', '0'))
        state_path = os.environ.get('FAKE_UIAUTOMATOR_ATTEMPTS')
        attempts = 1
        if state_path:
            p = Path(state_path)
            attempts = (int(p.read_text(encoding='utf-8')) if p.exists() else 0) + 1
            p.write_text(str(attempts), encoding='utf-8')
        if attempts <= fail_times:
            sys.stderr.write('ERROR: could not get idle state.\\n')
            sys.exit(1)
        print(f'UI hierchary dumped to: {tokens[2]}')
        sys.exit(0)

    sandbox = os.environ.get('FAKE_APP_FILES')
    if sandbox and tokens[:2] == ['am', 'start']:
        workspace = tokens[tokens.index('koe_workspace') + 1]
        Path(sandbox, 'active-workspace').write_text(workspace)
    if tokens and tokens[0] in ('am', 'run-as'):
        sys.exit(0)

    if tokens and tokens[0] == 'rm':
        sys.exit(0)

    sys.stderr.write(f'unexpected fake adb shell tokens: {tokens}\\n')
    sys.exit(1)

if rest[:2] == ['exec-out', 'run-as'] and rest[3] == 'cat' and os.environ.get('FAKE_APP_FILES'):
    path = Path(os.environ['FAKE_APP_FILES'], rest[4].removeprefix('files/'))
    sys.stdout.buffer.write(path.read_bytes())
    sys.exit(0)

if rest == ['exec-out', 'screencap', '-p']:
    sys.stdout.buffer.write(b'\\x89PNG\\r\\n\\x1a\\nFAKE_SCREEN_BYTES')
    sys.exit(0)

if len(rest) == 3 and rest[0] == 'pull':
    Path(rest[2]).write_text(
        '<?xml version="1.0" encoding="UTF-8"?><hierarchy rotation="0"><node text="Settings"/></hierarchy>\\n',
        encoding='utf-8',
    )
    sys.exit(0)

if rest and rest[0] == 'logcat':
    if '-b' in rest and 'crash' in rest:
        print('--------- beginning of crash')
        print('11-20 07:30:01.000  100  100 E AndroidRuntime: fake crash entry')
    else:
        print('--------- beginning of main')
        print('11-20 07:30:00.500  100  100 I KoeHarness: fake main log entry')
    sys.exit(0)

sys.stderr.write(f'unexpected fake adb args: {args}\\n')
sys.exit(1)
'''

FAKE_MAESTRO = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps([
            'maestro',
            *sys.argv[1:],
            {
                'MAESTRO_CLI_NO_ANALYTICS': os.environ.get('MAESTRO_CLI_NO_ANALYTICS'),
                'MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED': os.environ.get(
                    'MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED'
                ),
            },
        ]) + '\\n')

if os.environ.get('FAKE_APP_FILES'):
    files = Path(os.environ['FAKE_APP_FILES'])
    product = files / (files / 'active-workspace').read_text() / 'product-workspace.json'
    if Path(sys.argv[-1]).stem == 'restart':
        if json.loads(product.read_text())['records'][0]['id'] != 'survivor':
            sys.exit(1)
    else:
        product.parent.mkdir(parents=True, exist_ok=True)
        product.write_text(json.dumps({'records': [{'id': 'survivor'}]}))

if '--udid' not in sys.argv[1:]:
    sys.stderr.write('error: expected --udid flag on maestro test\\n')
    sys.exit(2)

for i, arg in enumerate(sys.argv[1:]):
    if arg == '--debug-output' and i + 2 < len(sys.argv):
        debug_dir = Path(sys.argv[i + 2])
        debug_dir.mkdir(parents=True, exist_ok=True)
        (debug_dir / 'maestro.log').write_text('fake maestro debug output\\n', encoding='utf-8')

sys.exit(int(os.environ.get('FAKE_MAESTRO_EXIT', '0')))
'''

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
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        path.chmod(0o755)
        return path

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
        if not self.call_log.exists():
            return []
        return [json.loads(line) for line in self.call_log.read_text(encoding='utf-8').splitlines() if line]

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
        return self.write_exec('bin/fake-slim', """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_CALL_LOG'], 'a') as log:
    print(json.dumps(['slim', *sys.argv[1:]]), file=log)
print('{"rss_mb": 256}')
""")

    def test_slim_snapshot_cold_boot_audio_and_workspace(self):
        snapshot = self.avd_home / 'koe-test-api35.avd/snapshots/avdslim_clean'
        tool = self.fake_slim()
        artifacts = self.root / 'evidence'
        args = ['--slim', '--with-audio', '--flow', str(SMOKE_FLOW), '--workspace', 'journeys',
                '--launch-app', '--app-package', 'com.semanticcraft.koe', '--artifacts-dir', str(artifacts)]
        for golden in (False, True):
            if golden:
                snapshot.mkdir(parents=True)
                source = snapshot.parents[1]
                (self.avd_home / 'koe-test-api35.ini').write_text(f'path={source}\n')
                (source / 'config.ini').write_text('fastboot.forceColdBoot=yes\n')
                (snapshot / 'hardware.ini').write_text('hw.ramSize = 1536\nfastboot.forceColdBoot = true\n')
                (snapshot / 'ram.bin').write_bytes(b'golden')
            result = self.run_verify(args, KOE_AVDSLIM_BIN=str(tool))
            self.assertEqual(result.returncode, 0, result.stderr)
            emulator = [c for c in self.read_calls() if c[0] == 'emulator'][-1]
            self.assertEqual(emulator[emulator.index('-gpu') + 1], 'host')
            self.assertNotIn('-no-audio', emulator)
            self.assertIn('-no-snapshot-save', emulator)
            if golden:
                self.assertEqual(emulator[emulator.index('-snapshot') + 1], 'avdslim_clean')
                self.assertNotIn('-no-snapshot-load', emulator)
                self.assertIn('-force-snapshot-load', emulator)
                self.assertIn('-lowram', emulator)
                self.assertEqual(emulator[emulator.index('-memory') + 1], '1536')
                self.assertEqual((source / 'config.ini').read_text(), 'fastboot.forceColdBoot=yes\n')
                self.assertIn('fastboot.forceColdBoot = true', (snapshot / 'hardware.ini').read_text())
                self.assertEqual((snapshot / 'ram.bin').read_bytes(), b'golden')
                self.assertEqual(list(self.avd_home.glob('.koe-verify-*')), [])
            else:
                self.assertIn('-no-snapshot-load', emulator)
        calls = self.read_calls()
        self.assertEqual(calls.count(['slim', 'on', 'emulator-5580', '--skip=bluetooth', '--no-anim']), 1)
        self.assertEqual(calls.count(['slim', 'measure', 'emulator-5580']), 2)
        self.assertEqual(sum('koe_workspace verify-workspaces/journeys' in c[-1] for c in calls if c[0] == 'adb'), 2)
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
        self.assertEqual(trace['avd'], 'koe-test-api35')
        self.assertEqual(trace['serial'], 'emulator-5580')
        self.assertEqual(trace['api_level'], '35')
        self.assertEqual(trace['abi'], 'arm64-v8a')
        self.assertEqual(trace['flow_exit_code'], 1)
        self.assertEqual(trace['outcome'], 'fail')
        self.assertIsNone(trace['host_intent_trace'])
        self.assertEqual(
            set(trace['artifacts'].keys()),
            {'screen', 'window_hierarchy', 'logcat', 'maestro_debug_dir'},
        )

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

    def test_android_shell_scripts_have_no_hardcoded_home_paths(self):
        scripts = sorted(ANDROID_DIR.glob('*.sh'))
        self.assertGreaterEqual(len(scripts), 2)
        pattern = re.compile(r'/Users/')
        for script in scripts:
            content = script.read_text(encoding='utf-8')
            self.assertIsNone(
                pattern.search(content),
                f'hardcoded personal home path found in {script.relative_to(ROOT)}',
            )

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
