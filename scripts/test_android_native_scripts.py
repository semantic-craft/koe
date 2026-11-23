#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
VERIFY_NATIVE = ROOT / 'platforms' / 'android' / 'verify-native.sh'

REQUIRED_C_SYMBOLS = [
    'koe_host_api_version',
    'koe_host_session_create',
    'koe_host_session_create_with_credentials',
    'koe_host_session_destroy',
    'koe_host_session_generation',
    'koe_host_session_snapshot_json',
    'koe_host_session_export_diagnostics_json',
    'koe_host_session_dispatch_json',
    'koe_host_session_ingest_ble',
    'koe_host_session_ingest_pcm',
    'koe_host_session_report_playback_progress',
    'koe_host_session_drain_ble_tx',
    'koe_host_session_drain_local_asr',
    'koe_host_session_poll_timers',
    'koe_host_bytes_free',
    'koe_host_string_free',
]

REQUIRED_JNI_SYMBOLS = [
    'JNI_OnLoad',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeApiVersion',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionCreate',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionCreateWithCredentials',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDestroy',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionGeneration',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionSnapshotJson',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionExportDiagnosticsJson',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDispatchJson',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionIngestBle',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionIngestPcm',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionReportPlaybackProgress',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDrainBleTx',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDrainLocalAsr',
    'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionPollTimers',
]

MOCK_READELF = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

spec = json.loads(Path(os.environ['MOCK_READELF_SPEC']).read_text(encoding='utf-8'))
args = sys.argv[1:]
lib = Path(args[-1]).name
entry = spec[lib]

if '-h' in args:
    print('ELF Header:')
    print(f"  Class:                             {entry['class']}")
    print(f"  Machine:                           {entry['machine']}")
    sys.exit(0)

if '-lW' in args:
    print('Program Headers:')
    print('  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align')
    for idx, align in enumerate(entry['load_aligns']):
        flg = 'R E' if idx == 1 else 'R  '
        print(f'  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x001000 0x001000 {flg} {align}')
    sys.exit(0)

if '-dW' in args:
    print('Dynamic section contains entries:')
    print('  Tag                Type              Name/Value')
    for dep in entry['needed']:
        print(f'  0x0000000000000001 (NEEDED)          Shared library: [{dep}]')
    for tag in entry.get('extra_tags', []):
        print(f'  0x000000006fffe000 ({tag})           0x1000')
    sys.exit(0)

if '--dyn-syms' in args:
    print("Symbol table '.dynsym' contains entries:")
    print('   Num:    Value          Size Type    Bind   Vis       Ndx Name')
    for idx, item in enumerate(entry.get('dynsyms', []), start=1):
        if isinstance(item, dict):
            name = item['name']
            ndx = item.get('ndx', '14')
            bind = item.get('bind', 'GLOBAL')
        else:
            name = item
            ndx = '14'
            bind = 'GLOBAL'
        print(f'  {idx:4d}: 0000000000001000    16 FUNC    {bind:<6} DEFAULT {ndx:>4} {name}')
    sys.exit(0)

sys.stderr.write(f'unexpected mock llvm-readelf args: {args}\\n')
sys.exit(2)
'''


class AndroidNativeScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.readelf = self.root / 'llvm-readelf'
        self.readelf.write_text(MOCK_READELF, encoding='utf-8')
        self.readelf.chmod(0o755)
        self.lib_dir = self.root / 'jniLibs'
        self.lib_dir.mkdir()
        for name in ('libkoe_host_api.so', 'libkoe_android.so', 'libc++_shared.so'):
            (self.lib_dir / name).write_bytes(b'\x7fELF')

    def valid_spec(self, machine='AArch64', align='0x4000'):
        return {
            'libkoe_host_api.so': {
                'class': 'ELF64',
                'machine': machine,
                'load_aligns': [align, align, align],
                'needed': ['libc.so', 'libm.so', 'libdl.so'],
                'extra_tags': ['ANDROID_RELR', 'ANDROID_RELRSZ', 'ANDROID_RELRENT'],
                'dynsyms': list(REQUIRED_C_SYMBOLS),
            },
            'libkoe_android.so': {
                'class': 'ELF64',
                'machine': machine,
                'load_aligns': [align, align],
                'needed': ['libkoe_host_api.so', 'libc++_shared.so', 'liblog.so', 'libdl.so', 'libc.so'],
                'extra_tags': [],
                'dynsyms': list(REQUIRED_JNI_SYMBOLS),
            },
            'libc++_shared.so': {
                'class': 'ELF64',
                'machine': machine,
                'load_aligns': [align, align],
                'needed': ['libc.so', 'libm.so', 'libdl.so'],
                'extra_tags': [],
                'dynsyms': [],
            },
        }

    def run_verify(self, spec, abi='arm64-v8a'):
        spec_path = self.root / 'spec.json'
        spec_path.write_text(json.dumps(spec), encoding='utf-8')
        env = dict(os.environ, MOCK_READELF_SPEC=str(spec_path))
        return subprocess.run(
            [str(VERIFY_NATIVE), str(self.readelf), str(self.lib_dir), abi],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def test_accepts_valid_arm64_and_x86_64_libraries(self):
        arm64 = self.run_verify(self.valid_spec('AArch64', '0x4000'), abi='arm64-v8a')
        self.assertEqual(arm64.returncode, 0, arm64.stderr)
        self.assertIn('verify-native passed', arm64.stdout)

        x86 = self.run_verify(
            self.valid_spec('Advanced Micro Devices X86-64', '0x10000'),
            abi='x86_64',
        )
        self.assertEqual(x86.returncode, 0, x86.stderr)

    def test_rejects_load_alignment_below_16kb(self):
        spec = self.valid_spec()
        spec['libkoe_android.so']['load_aligns'] = ['0x4000', '0x1000']
        result = self.run_verify(spec)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('16384', result.stderr)

    def test_rejects_forbidden_needed_dependency(self):
        spec = self.valid_spec()
        spec['libkoe_host_api.so']['needed'].append('libstdc++.so')
        result = self.run_verify(spec)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('libstdc++.so', result.stderr)

    def test_rejects_standard_relr_or_missing_android_relr(self):
        with_std_relr = self.valid_spec()
        with_std_relr['libkoe_host_api.so']['extra_tags'] = ['ANDROID_RELR', 'RELR']
        res_std = self.run_verify(with_std_relr)
        self.assertNotEqual(res_std.returncode, 0)
        self.assertIn('(RELR)', res_std.stderr)

        without_android_relr = self.valid_spec()
        without_android_relr['libkoe_host_api.so']['extra_tags'] = []
        res_missing = self.run_verify(without_android_relr)
        self.assertNotEqual(res_missing.returncode, 0)
        self.assertIn('ANDROID_RELR', res_missing.stderr)

    def test_rejects_missing_or_undefined_c_or_jni_symbol(self):
        missing_c = self.valid_spec()
        missing_c['libkoe_host_api.so']['dynsyms'].remove('koe_host_session_ingest_pcm')
        res_c = self.run_verify(missing_c)
        self.assertNotEqual(res_c.returncode, 0)
        self.assertIn('koe_host_session_ingest_pcm', res_c.stderr)

        undef_c = self.valid_spec()
        undef_c['libkoe_host_api.so']['dynsyms'] = [
            {'name': sym, 'ndx': 'UND'} if sym == 'koe_host_api_version' else sym
            for sym in REQUIRED_C_SYMBOLS
        ]
        res_undef = self.run_verify(undef_c)
        self.assertNotEqual(res_undef.returncode, 0)
        self.assertIn('koe_host_api_version', res_undef.stderr)

        missing_jni = self.valid_spec()
        missing_jni['libkoe_android.so']['dynsyms'].remove(
            'Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDrainLocalAsr'
        )
        res_jni = self.run_verify(missing_jni)
        self.assertNotEqual(res_jni.returncode, 0)
        self.assertIn('nativeSessionDrainLocalAsr', res_jni.stderr)

    def test_rejects_wrong_elf_class_or_machine(self):
        wrong_machine = self.valid_spec()
        wrong_machine['libkoe_host_api.so']['machine'] = 'ARM'
        res_mach = self.run_verify(wrong_machine)
        self.assertNotEqual(res_mach.returncode, 0)
        self.assertIn('AArch64', res_mach.stderr)

        wrong_class = self.valid_spec()
        wrong_class['libkoe_host_api.so']['class'] = 'ELF32'
        res_cls = self.run_verify(wrong_class)
        self.assertNotEqual(res_cls.returncode, 0)
        self.assertIn('ELF64', res_cls.stderr)

    def test_mobile_build_and_test_scripts_have_no_hardcoded_users_paths(self):
        scripts = sorted((ROOT / 'platforms' / 'android').glob('*.sh'))
        scripts += sorted((ROOT / 'platforms' / 'android' / 'tests' / 'jni').glob('*.sh'))
        scripts += sorted((ROOT / 'platforms' / 'ios').glob('*.sh'))
        scripts += sorted((ROOT / 'scripts' / 'lib').glob('*.sh'))
        self.assertGreaterEqual(len(scripts), 4)
        pattern = re.compile(r'/Users/')
        for script in scripts:
            content = script.read_text(encoding='utf-8')
            self.assertIsNone(
                pattern.search(content),
                f'hardcoded /Users/ path found in {script.relative_to(ROOT)}',
            )


if __name__ == '__main__':
    unittest.main()
