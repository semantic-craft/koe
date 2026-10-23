"""Run android-check against fake platform commands; never touch a device."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AndroidCheckTest(unittest.TestCase):
    def test_diarization_uses_isolated_package_and_copies_fixtures(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'scripts').mkdir()
            source = Path(os.environ.get('ANDROID_CHECK_UNDER_TEST', ROOT / 'scripts/android-check'))
            (root / 'scripts/android-check').write_text(source.read_text())
            bins = root / 'bin'
            bins.mkdir()
            log = root / 'calls'
            fake = '''#!/usr/bin/env python3
import json,os,pathlib,sys
with open(os.environ['CALL_LOG'],'a') as f:
 f.write(json.dumps([pathlib.Path(sys.argv[0]).name,sys.argv[1:],os.environ.get('KOE_ANDROID_VERIFICATION')])+'\\n')
a=' '.join(sys.argv[1:])
if 'get-state' in a: print('device')
elif 'getprop' in a: print('test-device')
elif 'run-as' in a and 'cat >' in a: sys.stdin.buffer.read()
elif sys.argv[1:2]==['test']: print('KOE_ADB: open-koe')
'''
            for name in ['adb', 'flutter']:
                path = bins / name
                path.write_text(fake)
                path.chmod(0o755)
            fixtures = root / 'fixtures'
            fixtures.mkdir()
            for name in ['segmentation-model.onnx', '3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx', '0-four-speakers-zh.wav']:
                (fixtures / name).write_bytes(b'fixture')
            (root / 'diarization_test.dart').touch()
            result = subprocess.run(['bash', str(root / 'scripts/android-check'), 'diarization_test.dart'], env={**os.environ, 'PATH': f'{bins}:{os.environ["PATH"]}', 'CALL_LOG': str(log), 'KOE_ANDROID_SERIAL': 'test-device', 'KOE_ANDROID_LOCK_DIR': str(root / 'device.lock'), 'KOE_DIARIZATION_FIXTURES': str(fixtures)}, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            import json
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            flutter = [call for call in calls if call[0] == 'flutter']
            self.assertTrue(flutter)
            self.assertTrue(all(call[2] == '1' for call in flutter), 'build/test must both select isolated application ID')
            copies = [call for call in calls if 'cat >' in ' '.join(call[1])]
            self.assertEqual(len(copies), 3)
            self.assertTrue(all('com.semanticcraft.soundcore.verification' in call[1] for call in copies))
            launches = [call for call in calls if 'start' in call[1]]
            self.assertTrue(launches)
            self.assertTrue(all('com.semanticcraft.soundcore.verification/com.semanticcraft.soundcore.MainActivity' in call[1] for call in launches))


if __name__ == '__main__':
    unittest.main()
