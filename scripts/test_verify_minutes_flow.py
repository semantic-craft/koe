import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('verify-minutes-flow')
loader = importlib.machinery.SourceFileLoader('verify_minutes_flow', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class VerificationEntryTest(unittest.TestCase):
    def run_mode(self, mode, env=None):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ)
            for key in ('DASHSCOPE_API_KEY', 'KOE_MINUTES_AUDIO',
                        'KOE_MINUTES_EXPECTATIONS'):
                environment.pop(key, None)
            environment.update(env or {})
            process = subprocess.run(
                ['python3', str(SCRIPT), mode, '--output-dir', directory],
                env=environment, capture_output=True, text=True, timeout=15,
            )
            receipts = list(Path(directory).glob('*/receipt.json'))
            self.assertEqual(len(receipts), 1, process.stdout + process.stderr)
            return process, json.loads(receipts[0].read_text())

    def test_provider_without_authorized_input_fails_with_receipt(self):
        result, receipt = self.run_mode('provider')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt['status'], 'blocked')
        self.assertNotIn('passed', [step['status'] for step in receipt['steps']])
        self.assertIn('KOE_MINUTES_AUDIO', receipt['steps'][0]['message'])

    def test_unimplemented_hardware_is_never_a_pass(self):
        result, receipt = self.run_mode('device')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt['status'], 'blocked')

    def test_flutter_skip_cannot_satisfy_gate(self):
        events = '\n'.join(json.dumps(value) for value in [
            {'type': 'testDone', 'skipped': True, 'result': 'success'},
            {'type': 'done', 'success': True},
        ])
        with self.assertRaises(module.Failed):
            module.flutter_result(events)

    def test_malformed_facts_return_receipt_instead_of_crashing(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / 'synthetic.wav'
            audio.write_bytes(b'synthetic-test-input')
            manifest = Path(directory) / 'expectations.json'
            manifest.write_text(json.dumps({
                'audio_sha256': hashlib.sha256(audio.read_bytes()).hexdigest(),
                'source_facts': [None],
            }))
            result, receipt = self.run_mode('provider', {
                'DASHSCOPE_API_KEY': 'synthetic-test-key',
                'KOE_MINUTES_AUDIO': str(audio),
                'KOE_MINUTES_EXPECTATIONS': str(manifest),
            })
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(receipt['status'], 'blocked')
            self.assertIn('source_facts', receipt['steps'][-1]['message'])

    def test_credentials_never_appear_in_receipt_or_console(self):
        secret = 'synthetic-secret-not-a-real-credential'
        result, receipt = self.run_mode('provider', {'DASHSCOPE_API_KEY': secret})
        self.assertNotIn(secret, result.stdout + result.stderr + json.dumps(receipt))


if __name__ == '__main__':
    unittest.main()
