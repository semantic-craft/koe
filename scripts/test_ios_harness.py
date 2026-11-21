#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
IOS_DIR = ROOT / 'platforms' / 'ios'
PROJECT_YML = IOS_DIR / 'project.yml'
INFO_PLIST = IOS_DIR / 'App' / 'Info.plist'
VERIFY_SCRIPT = IOS_DIR / 'verify-simulator.sh'
SMOKE_LIVE_FLOW = IOS_DIR / 'Tests' / 'maestro' / 'smoke-ios-live.yaml'
SMOKE_FIXTURE_FLOW = IOS_DIR / 'Tests' / 'maestro' / 'smoke-ios-fixture.yaml'
FAIL_PROBE_FLOW = IOS_DIR / 'Tests' / 'maestro' / 'fail-probe-ios.yaml'
FIXTURE_JSON = IOS_DIR / 'Tests' / 'Fixtures' / 'ios-rich-snapshot.json'


FAKE_JAVA = '''#!/usr/bin/env python3
import sys
sys.stderr.write('openjdk version "17.0.10"\\n')
sys.exit(0)
'''

FAKE_XCODEGEN = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['xcodegen', *sys.argv[1:]]) + '\\n')

spec_dir = Path.cwd()
args = sys.argv[1:]
for idx, arg in enumerate(args):
    if arg == '--project' and idx + 1 < len(args):
        spec_dir = Path(args[idx + 1]).resolve()
        break
    if arg == '--spec' and idx + 1 < len(args):
        spec_dir = Path(args[idx + 1]).resolve().parent

proj = spec_dir / 'KoeiOS.xcodeproj'
proj.mkdir(parents=True, exist_ok=True)
(proj / 'project.pbxproj').write_text('// fake pbxproj\\n', encoding='utf-8')
sys.exit(0)
'''

FAKE_XCODEBUILD = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['xcodebuild', *args]) + '\\n')

derived_data = None
for idx, arg in enumerate(args):
    if arg == '-derivedDataPath' and idx + 1 < len(args):
        derived_data = Path(args[idx + 1])

if derived_data is not None:
    app_dir = derived_data / 'Build' / 'Products' / 'Debug-iphonesimulator' / 'Koe.app'
    app_dir.mkdir(parents=True, exist_ok=True)
    (app_dir / 'Info.plist').write_text('fake', encoding='utf-8')

if 'test' in args and os.environ.get('FAKE_XCODEBUILD_TEST_EXIT'):
    sys.exit(int(os.environ['FAKE_XCODEBUILD_TEST_EXIT']))
sys.exit(int(os.environ.get('FAKE_XCODEBUILD_EXIT', '0')))
'''

FAKE_XCRUN = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['xcrun', *args]) + '\\n')

if not args or args[0] != 'simctl':
    sys.stderr.write(f'unexpected fake xcrun args: {args}\\n')
    sys.exit(1)

sub = args[1:]
if sub == ['list', 'devices', 'available', '-j']:
    primary_state = os.environ.get('FAKE_SIM_STATE', 'Shutdown')
    payload = {
        'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-18-2': [
                {
                    'udid': 'FAKE-IPHONE-16-UDID',
                    'name': 'iPhone 16',
                    'state': 'Shutdown',
                    'isAvailable': True,
                },
                {
                    'udid': 'FAKE-IPHONE-17-UDID',
                    'name': 'iPhone 17',
                    'state': primary_state,
                    'isAvailable': True,
                },
            ]
        }
    }
    print(json.dumps(payload))
    sys.exit(0)

if len(sub) >= 2 and sub[0] in ('boot', 'bootstatus', 'shutdown', 'install', 'terminate', 'launch', 'privacy'):
    if sub[0] == 'launch':
        container_dir = Path(os.environ['FAKE_APP_CONTAINER'])
        docs_dir = container_dir / 'Documents'
        docs_dir.mkdir(parents=True, exist_ok=True)
        trace_content = json.dumps([
            {
                'kind': 'event',
                'name': 'sync_app_metadata',
                'generation': 1,
                'section': 'today',
                'hasError': False,
                'timestampEpochMs': 1700000000000,
            }
        ])
        (docs_dir / 'koe-trace.json').write_text(trace_content + '\\n', encoding='utf-8')
        for idx, arg in enumerate(sub):
            if arg == '-koe-workspace':
                (container_dir / 'launched-workspace').write_text(sub[idx + 1], encoding='utf-8')
            if arg == '-koe-trace-output' and idx + 1 < len(sub):
                target = Path(sub[idx + 1])
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(trace_content + '\\n', encoding='utf-8')
    sys.exit(0)

if len(sub) >= 4 and sub[0] == 'get_app_container':
    container_dir = Path(os.environ['FAKE_APP_CONTAINER'])
    (container_dir / 'Documents').mkdir(parents=True, exist_ok=True)
    print(str(container_dir))
    sys.exit(0)

if len(sub) == 4 and sub[0] == 'io' and sub[2] == 'screenshot':
    if os.environ.get('FAKE_SIMCTL_SCREENSHOT_HANG') == '1':
        import time
        time.sleep(60)
    out = Path(sub[3])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b'\\x89PNG\\r\\n\\x1a\\nFAKE_IOS_SCREEN')
    sys.exit(0)

if len(sub) >= 3 and sub[0] == 'spawn' and sub[2] == 'log':
    print('2026-11-20 09:30:00.000 Df Koe[1234:5678] [com.semanticcraft.koe:host] ready')
    sys.exit(0)

sys.stderr.write(f'unexpected fake simctl subcommand: {sub}\\n')
sys.exit(1)
'''

FAKE_MAESTRO = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps([
            'maestro',
            *args,
            {
                'MAESTRO_CLI_NO_ANALYTICS': os.environ.get('MAESTRO_CLI_NO_ANALYTICS'),
                'MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED': os.environ.get(
                    'MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED'
                ),
            },
        ]) + '\\n')

if 'hierarchy' in args:
    print('{"attributes":{"text":"模式选择","accessibilityText":"模式选择"},"children":[]}')
    sys.exit(0)

if '--udid' not in args:
    sys.stderr.write('error: expected --udid flag on maestro test\\n')
    sys.exit(2)

for idx, arg in enumerate(args):
    if arg == '--debug-output' and idx + 1 < len(args):
        debug_dir = Path(args[idx + 1])
        debug_dir.mkdir(parents=True, exist_ok=True)
        (debug_dir / 'maestro.log').write_text('fake maestro ios log\\n', encoding='utf-8')
        if os.environ.get('FAKE_MAESTRO_WRITE_PNG') == '1':
            shot_dir = debug_dir / 'screenshots'
            shot_dir.mkdir(parents=True, exist_ok=True)
            (shot_dir / 'final_screen.png').write_bytes(b'\\x89PNG\\r\\n\\x1a\\nMAESTRO_FALLBACK_SCREEN')

container_dir = os.environ.get('FAKE_APP_CONTAINER')
if container_dir:
    docs_dir = Path(container_dir) / 'Documents'
    docs_dir.mkdir(parents=True, exist_ok=True)
    if Path(args[-1]).name == 'smoke-ios-live.yaml':
        workspace_dir = Path((Path(container_dir) / 'launched-workspace').read_text(encoding='utf-8'))
        (workspace_dir / 'product-workspace.json').write_text(
            json.dumps({'provider': {'model': 'deepseek-v4-pro'}}), encoding='utf-8')
    trace_file = docs_dir / 'koe-trace.json'
    if not trace_file.exists():
        trace_file.write_text(json.dumps([
            {
                'kind': 'command',
                'name': 'create_note',
                'generation': 2,
                'section': 'today',
                'hasError': False,
                'timestampEpochMs': 1700000001000,
            }
        ]) + '\\n', encoding='utf-8')

sys.exit(int(os.environ.get('FAKE_MAESTRO_EXIT', '0')))
'''


class IOSProjectContractTest(unittest.TestCase):
    def test_project_yml_and_info_plist_contracts(self):
        self.assertTrue(PROJECT_YML.is_file(), f'missing {PROJECT_YML}')
        yml = PROJECT_YML.read_text(encoding='utf-8')

        self.assertIn('createIntermediateGroups: false', yml)
        self.assertRegex(yml, r'iOS:\s*"?17\.0"?')
        self.assertIn('KoeAppleShared:', yml)
        self.assertIn('path: ../apple-shared', yml)
        self.assertIn('product: KoeAppleCore', yml)
        self.assertNotIn('product: KoeAppleShared', yml)
        self.assertIn('LIBRARY_SEARCH_PATHS[sdk=iphoneos*]', yml)
        self.assertIn('$(PROJECT_DIR)/../../target/ios/device', yml)
        self.assertIn('LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]', yml)
        self.assertIn('$(PROJECT_DIR)/../../target/ios/simulator', yml)
        self.assertIn('-lkoe_host_api', yml)
        self.assertRegex(yml, r'CODE_SIGNING_ALLOWED\[sdk=iphonesimulator\*\]:\s*"?NO"?')
        self.assertIn('KoeiOSTests:', yml)
        self.assertIn('type: bundle.unit-test', yml)
        self.assertIn('schemes:', yml)
        self.assertIn('KoeiOSApp:', yml)

        self.assertTrue(INFO_PLIST.is_file(), f'missing {INFO_PLIST}')
        plist = plistlib.loads(INFO_PLIST.read_bytes())
        self.assertEqual(plist.get('CFBundleDisplayName'), 'Koe')
        self.assertIn('UILaunchScreen', plist)
        for key in (
            'NSMicrophoneUsageDescription',
            'NSBluetoothAlwaysUsageDescription',
            'NSSpeechRecognitionUsageDescription',
        ):
            val = plist.get(key)
            self.assertIsInstance(val, str, f'{key} must be string')
            self.assertTrue(val.strip(), f'{key} must be non-empty')
        bg_modes = plist.get('UIBackgroundModes', [])
        self.assertIn('bluetooth-central', bg_modes)
        self.assertIn('audio', bg_modes)


class IOSSimulatorHarnessTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        self.java_home = self.root / 'jdk'
        self.write_exec('jdk/bin/java', FAKE_JAVA)
        self.xcrun_bin = self.write_exec('bin/xcrun', FAKE_XCRUN)
        self.xcodegen_bin = self.write_exec('bin/xcodegen', FAKE_XCODEGEN)
        self.xcodebuild_bin = self.write_exec('bin/xcodebuild', FAKE_XCODEBUILD)
        self.maestro_bin = self.write_exec('bin/maestro', FAKE_MAESTRO)

        self.call_log = self.root / 'calls.jsonl'
        self.app_container = self.root / 'app-container'
        self.app_container.mkdir(parents=True, exist_ok=True)
        self.derived_data = self.root / 'derived-data'
        self.fake_native_lib = self.root / 'libkoe_host_api.a'
        self.fake_native_lib.write_bytes(b'!<arch>\n')

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
            KOE_XCRUN_BIN=str(self.xcrun_bin),
            KOE_XCODEGEN_BIN=str(self.xcodegen_bin),
            KOE_XCODEBUILD_BIN=str(self.xcodebuild_bin),
            KOE_MAESTRO_BIN=str(self.maestro_bin),
            KOE_IOS_DERIVED_DATA=str(self.derived_data),
            KOE_IOS_PROJECT_DIR=str(self.root / 'xcodegen-out'),
            KOE_IOS_SIM_LIB=str(self.fake_native_lib),
            FAKE_CALL_LOG=str(self.call_log),
            FAKE_APP_CONTAINER=str(self.app_container),
        )
        env.update(extra)
        return env

    def read_calls(self):
        if not self.call_log.exists():
            return []
        return [json.loads(line) for line in self.call_log.read_text(encoding='utf-8').splitlines() if line]

    def run_verify(self, args, **env_extra):
        self.assertTrue(VERIFY_SCRIPT.is_file(), f'missing {VERIFY_SCRIPT}')
        return subprocess.run(
            [str(VERIFY_SCRIPT), *args],
            cwd=ROOT,
            env=self.base_env(**env_extra),
            capture_output=True,
            text=True,
            timeout=30,
        )

    def assert_four_artifacts(self, artifacts_dir: Path):
        for name in ('screen.png', 'view_hierarchy.txt', 'syslog.txt', 'trace.json'):
            path = artifacts_dir / name
            self.assertTrue(path.exists() and path.stat().st_size > 0, f'missing or empty {name} in {artifacts_dir}')
        self.assertTrue((artifacts_dir / 'screen.png').read_bytes().startswith(b'\x89PNG'))
        trace = json.loads((artifacts_dir / 'trace.json').read_text(encoding='utf-8'))
        self.assertIsInstance(trace, (dict, list))

    def fake_slim(self):
        return self.write_exec('bin/fake-slim', """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_CALL_LOG'], 'a') as log:
    print(json.dumps(['slim', *sys.argv[1:]]), file=log)
print('{"rss_mb": 256}')
""")

    def test_slim_profile_doctor_metrics_and_workspace_relaunch(self):
        artifacts = self.root / 'slim'
        workspace = self.root / 'persisted'
        tool = self.fake_slim()
        profile = self.root / 'profile.json'
        profile.write_text('{"name":"test","keep":[],"except":["search","icloud","siri"]}')
        udid = 'FAKE-IPHONE-17-UDID'
        args = ['--slim', '--udid', udid, '--slim-profile', str(profile),
                '--flow', str(SMOKE_LIVE_FLOW), '--workspace', str(workspace),
                '--artifacts-dir', str(artifacts)]
        for state in ('Shutdown', 'Booted'):
            result = self.run_verify(args, FAKE_SIM_STATE=state, KOE_SIMSLIM_BIN=str(tool))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path((self.app_container / 'launched-workspace').read_text()), workspace)
            self.assertTrue((workspace / 'product-workspace.json').is_file())
            marker = workspace / 'restart-marker'
            if state == 'Booted':
                self.assertEqual(marker.read_text(), 'survivor')
            marker.write_text('survivor')
        calls = self.read_calls()
        for args in (['on', udid, '--no-reboot', '--profile', str(profile)],
                     ['doctor', udid, '--requires', 'files-recents,siri'], ['measure', udid, '--json']):
            self.assertEqual(calls.count(['slim', *args]), 2)
        self.assertEqual(json.loads((artifacts / 'simslim-metrics.json').read_text())['rss_mb'], 256)

    def test_restart_flow_preserves_live_artifacts_and_uses_project_slim_profile(self):
        restart = self.root / 'restart.yaml'
        restart.write_text('appId: com.semanticcraft.koe.ios\n---\n- assertVisible: survivor\n')
        live = self.root / 'evidence/live'
        result = self.run_verify(['--slim', '--flow', str(SMOKE_LIVE_FLOW), '--workspace', 'persistent',
                                  '--restart-flow', str(restart), '--artifacts-dir', str(live)],
                                 FAKE_SIM_STATE='Shutdown', KOE_SIMSLIM_BIN=str(self.fake_slim()))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.read_calls()
        self.assertIn(['slim', 'on', 'FAKE-IPHONE-17-UDID', '--no-reboot', '--profile',
                       str(ROOT / 'platforms/ios/simslim-koe.json')], calls)
        launches = [c for c in calls if c[:3] == ['xcrun', 'simctl', 'launch']]
        self.assertEqual(len(launches), 2)
        workspaces = [c[c.index('-koe-workspace') + 1] for c in launches]
        self.assertEqual(workspaces[0], workspaces[1])
        for phase in (live, live.parent / 'restart'):
            state = json.loads((phase / 'workspace/product-workspace.json').read_text())
            self.assertEqual(state['provider']['model'], 'deepseek-v4-pro')

    def test_slim_missing_and_implicit_booted_device(self):
        for tool, state in ((self.root / 'missing', 'Shutdown'), (self.fake_slim(), 'Booted')):
            result = self.run_verify(['--slim', '--flow', str(SMOKE_LIVE_FLOW),
                                      '--artifacts-dir', str(self.root / 'out')],
                                     KOE_SIMSLIM_BIN=str(tool), FAKE_SIM_STATE=state)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('simslim', result.stderr)
        self.assertFalse(any(c[0] == 'slim' for c in self.read_calls()))

    def test_green_path_boots_runs_flow_collects_artifacts_and_shuts_down(self):
        artifacts_dir = self.root / 'green-artifacts'
        result = self.run_verify(
            ['--flow', str(SMOKE_LIVE_FLOW), '--keep-artifacts', '--artifacts-dir', str(artifacts_dir)],
            FAKE_SIM_STATE='Shutdown',
            FAKE_MAESTRO_EXIT='0',
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_four_artifacts(artifacts_dir)

        calls = self.read_calls()
        self.assertTrue(any(c[:3] == ['xcrun', 'simctl', 'boot'] and 'FAKE-IPHONE-17-UDID' in c for c in calls))
        self.assertTrue(any(c[:3] == ['xcrun', 'simctl', 'shutdown'] and 'FAKE-IPHONE-17-UDID' in c for c in calls))
        self.assertTrue(any(c[0] == 'xcodegen' for c in calls))
        self.assertTrue(any(c[0] == 'xcodebuild' for c in calls))
        maestro_tests = [c for c in calls if c[0] == 'maestro' and len(c) > 1 and c[1] == 'test']
        self.assertEqual(len(maestro_tests), 1)
        self.assertIn('FAKE-IPHONE-17-UDID', maestro_tests[0])

    def test_self_check_runs_unit_tests_and_live_plus_fixture_flows(self):
        artifacts_dir = self.root / 'self-check-artifacts'
        result = self.run_verify(
            ['--self-check', '--keep-artifacts', '--artifacts-dir', str(artifacts_dir)],
            FAKE_SIM_STATE='Shutdown',
            FAKE_MAESTRO_EXIT='0',
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_four_artifacts(artifacts_dir / 'live')
        self.assert_four_artifacts(artifacts_dir / 'fixture')

        calls = self.read_calls()
        self.assertTrue(any(c[0] == 'xcodebuild' and 'test' in c for c in calls))
        maestro_tests = [c for c in calls if c[0] == 'maestro' and len(c) > 1 and c[1] == 'test']
        self.assertEqual(len(maestro_tests), 2)
        joined = [' '.join(str(x) for x in call) for call in maestro_tests]
        self.assertTrue(any('smoke-ios-live.yaml' in item for item in joined))
        self.assertTrue(any('smoke-ios-fixture.yaml' in item for item in joined))

    def test_red_path_collects_four_forensics_artifacts_and_exits_nonzero(self):
        artifacts_dir = self.root / 'red-artifacts'
        result = self.run_verify(
            ['--flow', str(FAIL_PROBE_FLOW), '--artifacts-dir', str(artifacts_dir)],
            FAKE_SIM_STATE='Shutdown',
            FAKE_MAESTRO_EXIT='1',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assert_four_artifacts(artifacts_dir)
        calls = self.read_calls()
        self.assertTrue(any(c[:3] == ['xcrun', 'simctl', 'shutdown'] and 'FAKE-IPHONE-17-UDID' in c for c in calls))

    def test_expect_failure_contract(self):
        expected_dir = self.root / 'expect-fail'
        expected = self.run_verify(
            ['--flow', str(FAIL_PROBE_FLOW), '--expect-failure', '--artifacts-dir', str(expected_dir)],
            FAKE_SIM_STATE='Shutdown',
            FAKE_MAESTRO_EXIT='1',
        )
        self.assertEqual(expected.returncode, 0, expected.stderr + expected.stdout)
        self.assert_four_artifacts(expected_dir)

        unexpected_dir = self.root / 'unexpected-pass'
        unexpected = self.run_verify(
            ['--flow', str(SMOKE_LIVE_FLOW), '--expect-failure', '--artifacts-dir', str(unexpected_dir)],
            FAKE_SIM_STATE='Shutdown',
            FAKE_MAESTRO_EXIT='0',
        )
        self.assertNotEqual(unexpected.returncode, 0)

    def test_preserves_already_booted_simulator(self):
        artifacts_dir = self.root / 'already-booted'
        result = self.run_verify(
            ['--flow', str(SMOKE_LIVE_FLOW), '--skip-build', '--artifacts-dir', str(artifacts_dir)],
            FAKE_SIM_STATE='Booted',
            FAKE_MAESTRO_EXIT='0',
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        calls = self.read_calls()
        self.assertFalse(any(c[:3] == ['xcrun', 'simctl', 'boot'] for c in calls))
        self.assertFalse(any(c[:3] == ['xcrun', 'simctl', 'shutdown'] for c in calls))

    def test_missing_tool_fails_fast_before_booting_simulator(self):
        missing_maestro = self.root / 'nonexistent-maestro'
        result = self.run_verify(
            ['--flow', str(SMOKE_LIVE_FLOW)],
            KOE_MAESTRO_BIN=str(missing_maestro),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('maestro', result.stderr.lower())
        calls = self.read_calls()
        self.assertFalse(any(c[:3] == ['xcrun', 'simctl', 'boot'] for c in calls))

    def test_hanging_simctl_screenshot_times_out_and_falls_back_to_maestro_screenshot(self):
        artifacts_dir = self.root / 'hang-fallback'
        result = self.run_verify(
            ['--flow', str(SMOKE_LIVE_FLOW), '--skip-build', '--keep-artifacts', '--artifacts-dir', str(artifacts_dir)],
            FAKE_SIM_STATE='Booted',
            FAKE_MAESTRO_EXIT='0',
            FAKE_SIMCTL_SCREENSHOT_HANG='1',
            FAKE_MAESTRO_WRITE_PNG='1',
            KOE_IOS_FORENSICS_TIMEOUT='1',
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_four_artifacts(artifacts_dir)
        self.assertIn(b'MAESTRO_FALLBACK_SCREEN', (artifacts_dir / 'screen.png').read_bytes())

    def test_ios_shell_scripts_have_no_hardcoded_home_paths(self):
        scripts = sorted(IOS_DIR.glob('*.sh'))
        self.assertGreaterEqual(len(scripts), 2)
        pattern = re.compile(r'/Users/')
        for script in scripts:
            content = script.read_text(encoding='utf-8')
            self.assertIsNone(
                pattern.search(content),
                f'hardcoded personal home path found in {script.relative_to(ROOT)}',
            )


if __name__ == '__main__':
    unittest.main()
