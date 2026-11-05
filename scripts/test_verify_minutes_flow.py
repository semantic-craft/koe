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
            verification.environment.pop('DASHSCOPE_API_KEY', None)
            verification.environment.pop('KOE_MINUTES_DEVICE', None)
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
            verification.environment.pop('DASHSCOPE_API_KEY', None)
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

    def run_macos_device(self, *, proof=True, physical_button=False):
        with tempfile.TemporaryDirectory() as directory:
            verification = module.Verification('device', Path(directory))
            verification.environment['KOE_MINUTES_DEVICE'] = 'macos'
            verification.environment['DASHSCOPE_API_KEY'] = 'synthetic-test-key'

            def command(name, argv, timeout=1200, provider=False):
                screenshots = verification.directory / 'screenshots'
                screenshots.mkdir(parents=True, exist_ok=True)
                (screenshots / 'device_minutes_reopened.png').write_bytes(b'png')
                if proof:
                    payload = {
                        'device_minutes_flow': {
                            'd3200_input': True,
                            'real_asr': True,
                            'recording_updates': True,
                            'stop_finalization': True,
                            'process_restart_readback': True,
                            'physical_button': physical_button,
                            'input_sha256': 'b' * 64,
                            'device_id': 'D3200-ID',
                            'device_mac': '48:79:7A:17:46:3D',
                        },
                    }
                    (verification.directory / 'device-proof.json').write_text(
                        json.dumps(payload))
                return 'All tests passed.'

            with patch.object(module.sys, 'platform', 'darwin'), \
                    patch.object(verification, 'suspend_background_koe_app', return_value=False), \
                    patch.object(verification, 'command', side_effect=command):
                code = verification.execute()
            return code, verification.receipt

    def test_macos_device_gate_records_verified_coverage_and_unverified_button(self):
        code, receipt = self.run_macos_device(proof=True, physical_button=False)
        self.assertEqual(code, 0)
        self.assertEqual(receipt['status'], 'passed')
        self.assertEqual(receipt['device_coverage']['d3200_input'], 'verified')
        self.assertEqual(receipt['device_coverage']['real_asr'], 'verified')
        self.assertEqual(receipt['device_coverage']['recording_updates'], 'verified')
        self.assertEqual(receipt['device_coverage']['stop_finalization'], 'verified')
        self.assertEqual(receipt['device_coverage']['process_restart_readback'], 'verified')
        self.assertEqual(receipt['device_coverage']['physical_button'], 'unverified')
        self.assertEqual(receipt['device_blockers'], ['physical_button_unverified'])

    def test_macos_device_gate_rejects_missing_proof(self):
        code, receipt = self.run_macos_device(proof=False)
        self.assertEqual(code, 1)
        self.assertEqual(receipt['status'], 'failed')
        self.assertIn('proof', receipt['steps'][-1]['message'])

    def run_mcp(self, *, proof=True, skipped=False):
        with tempfile.TemporaryDirectory() as directory:
            verification = module.Verification('mcp', Path(directory))
            def command(name, argv, timeout=1200, provider=False):
                if proof:
                    payload = {key: True for key in (
                        'automatic_publication', 'persistent_client',
                        'continued_transcript', 'corrected_transcript',
                        'minutes_updated', 'revision_guard', 'revoked',
                        'ungranted_denied')}
                    payload['input_sha256'] = 'a' * 64
                    (verification.directory / 'mcp-proof.json').write_text(json.dumps(payload))
                return '\n'.join(json.dumps(event) for event in [
                    {'type': 'testDone', 'skipped': skipped, 'result': 'success'},
                    {'type': 'done', 'success': True}])
            with patch.object(verification, 'command', side_effect=command):
                code = verification.execute()
            return code, verification.receipt

    def test_mcp_gate_accepts_complete_client_evidence(self):
        code, receipt = self.run_mcp()
        self.assertEqual(code, 0)
        self.assertEqual(receipt['status'], 'passed')
        self.assertEqual(receipt['input_sha256'], 'a' * 64)

    def test_mcp_gate_rejects_missing_behavior_proof(self):
        code, receipt = self.run_mcp(proof=False)
        self.assertEqual(code, 1)
        self.assertIn('proof', receipt['steps'][-1]['message'])

    def test_mcp_gate_rejects_skipped_client_test(self):
        code, receipt = self.run_mcp(skipped=True)
        self.assertEqual(code, 1)
        self.assertEqual(receipt['status'], 'failed')

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
