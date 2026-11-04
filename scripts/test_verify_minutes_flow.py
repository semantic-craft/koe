import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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

    def test_device_command_failure_always_leaves_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            verification = module.Verification('device', Path(directory))
            with patch.object(module.sys, 'platform', 'darwin'), \
                    patch.object(verification, 'command', side_effect=module.Failed(
                        'device-inventory interrupted or timed out')):
                code = verification.execute()
            receipt = json.loads((verification.directory / 'receipt.json').read_text())
            self.assertEqual(code, 1)
            self.assertEqual(receipt['status'], 'failed')
            self.assertIn('timed out', receipt['steps'][-1]['message'])
            self.assertEqual(receipt['device_coverage']['physical_button'], 'unverified')

    def device_run(self, devices, lock=None):
        with tempfile.TemporaryDirectory() as directory:
            verification = module.Verification('device', Path(directory))
            verification.environment.pop('KOE_MINUTES_DEVICE', None)
            commands = []

            def command(name, argv, timeout=1200, provider=False):
                commands.append(argv)
                payload = ({'devices': devices} if name == 'device-inventory'
                           else lock or {})
                output = Path(argv[argv.index('--json-output') + 1])
                output.write_text(json.dumps({'info': {'outcome': 'success'},
                                             'result': payload}))
                return ''

            with patch.object(module.sys, 'platform', 'darwin'), \
                    patch.object(verification, 'command', side_effect=command):
                code = verification.execute()
            return code, verification.receipt, commands

    def test_device_simulator_cannot_satisfy_physical_gate(self):
        code, receipt, commands = self.device_run([{
            'identifier': 'simulator',
            'properties': {'hardware': {'reality': 'simulated',
                                        'deviceType': 'iPhone'}}}])
        self.assertEqual(code, 77)
        self.assertIn('physical iPhone', receipt['steps'][-1]['message'])
        self.assertEqual(len(commands), 1)
        self.assertEqual(receipt['device_coverage']['physical_button'], 'unverified')

    def test_locked_phone_records_observation_without_installing(self):
        code, receipt, commands = self.device_run([{
            'identifier': 'physical-phone',
            'properties': {'hardware': {'reality': 'physical',
                                        'deviceType': 'iPhone', 'udid': 'udid'}}}],
            {'passcodeRequired': True, 'unlockedSinceBoot': True})
        self.assertEqual(code, 77)
        self.assertTrue(receipt['device']['passcode_required'])
        self.assertIn('locked', receipt['steps'][-1]['message'])
        self.assertEqual(len(commands), 2)
        self.assertEqual(receipt['device_coverage']['d3200_input'], 'unverified')

    def test_unlocked_phone_is_not_device_minutes_acceptance(self):
        code, receipt, commands = self.device_run([{
            'identifier': 'physical-phone',
            'properties': {'hardware': {'reality': 'physical',
                                        'deviceType': 'iPhone', 'udid': 'udid'}}}],
            {'passcodeRequired': False, 'unlockedSinceBoot': True})
        self.assertEqual(code, 77)
        self.assertIn('stop', receipt['steps'][-1]['message'])
        self.assertEqual(len(commands), 2)
        self.assertEqual(receipt['device_coverage']['stop_finalization'], 'unverified')

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
