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

    def test_all_mode_runs_all_five_layers_and_records_status_breakdown(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / 'authorized.wav'
            audio.write_bytes(b'authorized-audio-bytes')
            audio_sha = hashlib.sha256(audio.read_bytes()).hexdigest()
            manifest = Path(directory) / 'expectations.json'
            manifest.write_text(json.dumps({
                'audio_sha256': audio_sha,
                'source_facts': [
                    {'kind': 'reason', 'source': '地址', 'minutes': '地址'},
                    {'kind': 'example', 'source': '门牌号', 'minutes': '门牌号'},
                    {'kind': 'correction', 'source': '下周一', 'minutes': '下周一'},
                    {'kind': 'unknown', 'source': '还没确定', 'minutes': '未定'},
                    {'kind': 'negation', 'source': '不采用自动发布', 'minutes': '不采用自动发布'},
                ],
                'forbidden_minutes': ['资料已经核对完成'],
            }))
            verification = module.Verification('all', Path(directory))
            verification.environment['DASHSCOPE_API_KEY'] = 'synthetic-test-key'
            verification.environment['KOE_MINUTES_AUDIO'] = str(audio)
            verification.environment['KOE_MINUTES_EXPECTATIONS'] = str(manifest)
            verification.environment['KOE_MINUTES_DEVICE'] = 'macos'

            def command(name, argv, timeout=1200, provider=False):
                screenshots = verification.directory / 'screenshots'
                screenshots.mkdir(parents=True, exist_ok=True)
                if name == 'offline-tests':
                    (verification.directory / 'offline-proof.json').write_text(json.dumps({
                        'minutes_flow': {
                            'durable_readback': True,
                            'chapters': True,
                            'overflow_checked': True,
                            'reopened': True,
                            'live_draft_recovered': True,
                            'input_sha256': audio_sha,
                        },
                    }))
                    return '\n'.join(json.dumps(e) for e in [
                        {'type': 'testDone', 'skipped': False, 'result': 'success'},
                        {'type': 'done', 'success': True},
                    ])
                if name == 'simulator-inventory':
                    return json.dumps({
                        'runtimes': [{
                            'isAvailable': True,
                            'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-18-0',
                            'version': '18.0',
                            'supportedDeviceTypes': [{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-15'}],
                        }],
                        'devicetypes': [{
                            'productFamily': 'iPhone',
                            'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-15',
                        }],
                    })
                if name == 'simulator-create':
                    return '11111111-2222-3333-4444-555555555555'
                if name in ('simulator-boot', 'simulator-ready', 'simulator-delete'):
                    return ''
                if name == 'ios-flow':
                    (screenshots / 'minutes-chapters.png').write_bytes(b'png')
                    (verification.directory / 'ios-proof.json').write_text(json.dumps({
                        'minutes_flow': {
                            'durable_readback': True,
                            'chapters': True,
                            'overflow_checked': True,
                            'reopened': True,
                            'live_draft_recovered': True,
                            'input_sha256': audio_sha,
                        },
                    }))
                    return 'All tests passed.'
                if name == 'provider-flow':
                    (verification.directory / 'provider-proof.json').write_text(json.dumps({
                        'real_asr': True,
                        'real_llm': True,
                        'persisted_readback': True,
                        'facts_and_sources_checked': True,
                        'input_sha256': audio_sha,
                    }))
                    return '\n'.join(json.dumps(e) for e in [
                        {'type': 'testDone', 'skipped': False, 'result': 'success'},
                        {'type': 'done', 'success': True},
                    ])
                if name == 'device-flow':
                    (screenshots / 'device_minutes_reopened.png').write_bytes(b'png')
                    (verification.directory / 'device-proof.json').write_text(json.dumps({
                        'device_minutes_flow': {
                            'd3200_input': True,
                            'real_asr': True,
                            'recording_updates': True,
                            'stop_finalization': True,
                            'process_restart_readback': True,
                            'physical_button': False,
                            'input_sha256': audio_sha,
                            'device_id': 'D3200-ID',
                            'device_mac': '00:7F:1D:06:63:9D',
                        },
                    }))
                    return 'All tests passed.'
                if name == 'mcp-client-flow':
                    (verification.directory / 'mcp-proof.json').write_text(json.dumps({
                        'automatic_publication': True,
                        'persistent_client': True,
                        'continued_transcript': True,
                        'corrected_transcript': True,
                        'minutes_updated': True,
                        'revision_guard': True,
                        'revoked': True,
                        'ungranted_denied': True,
                        'input_sha256': audio_sha,
                    }))
                    return '\n'.join(json.dumps(e) for e in [
                        {'type': 'testDone', 'skipped': False, 'result': 'success'},
                        {'type': 'done', 'success': True},
                    ])
                raise AssertionError(f'unexpected command {name}')

            with patch.object(module.sys, 'platform', 'darwin'), \
                    patch.object(verification, 'suspend_background_koe_app', return_value=False), \
                    patch.object(verification, 'command', side_effect=command):
                code = verification.execute()
            self.assertEqual(code, 0)
            receipt = verification.receipt
            self.assertEqual(receipt['status'], 'passed')
            self.assertEqual(set(receipt['modes'].keys()), set(module.MODES))
            for mode in module.MODES:
                self.assertEqual(receipt['modes'][mode]['status'], 'passed')
            self.assertEqual(
                receipt['modes']['provider']['service_evidence'],
                'authorized test audio via real DashScope Qwen ASR and LLM',
            )
            self.assertIsNone(receipt['modes']['provider']['device'])
            self.assertIsNone(receipt['modes']['provider']['device_coverage'])
            self.assertEqual(receipt['modes']['mcp']['models'], {})
            self.assertIsNone(receipt['modes']['mcp']['device'])
            self.assertIsNone(receipt['modes']['mcp']['device_coverage'])
            self.assertEqual(receipt['modes']['device']['device']['kind'], 'macOS CoreBluetooth + D3200')
            self.assertEqual(receipt['modes']['device']['device_coverage']['d3200_input'], 'verified')
            self.assertEqual(receipt['input_sha256'], audio_sha)
            self.assertIn('installation_status', receipt)
            self.assertIn('merge_status', receipt)
            self.assertIn('acceptance_breakdown', receipt)


if __name__ == '__main__':
    unittest.main()
