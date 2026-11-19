#!/usr/bin/env python3
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).with_name('run-with-secrets.py')


class RunWithSecretsTest(unittest.TestCase):
    def test_forwards_qwen_and_deepseek_keys_and_strips_unrelated_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = root / 'run-with-secrets.py'
            script.write_text(SOURCE.read_text())
            out = root / 'env.json'
            helper = root / 'launch-macos.swift'
            helper.write_text(
                'import Foundation\n'
                'let env = ProcessInfo.processInfo.environment\n'
                'let data = try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])\n'
                f'try data.write(to: URL(fileURLWithPath: {json.dumps(str(out))}))\n'
            )
            env = {
                'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
                'HOME': os.environ.get('HOME', tmp),
                'DASHSCOPE_API_KEY': 'fixture-qwen',
                'DEEPSEEK_API_KEY': 'fixture-deepseek',
                'DB_PASSWORD': 'should-be-stripped',
                'SSH_AUTH_SOCK': '/tmp/ssh-agent.sock',
                'lowercase_secret': 'should-be-stripped',
                'API_CREDENTIAL': 'should-be-stripped',
                'UNRELATED_SECRET': 'should-be-stripped',
                'OTHER_API_TOKEN': 'should-be-stripped',
            }
            result = subprocess.run(
                ['python3', str(script), 'macos'],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            forwarded = json.loads(out.read_text())
            self.assertEqual(forwarded.get('KOE_CREDENTIAL_SOURCE'), 'environment')
            self.assertEqual(forwarded.get('DASHSCOPE_API_KEY'), 'fixture-qwen')
            self.assertEqual(forwarded.get('DEEPSEEK_API_KEY'), 'fixture-deepseek')
            for stripped in (
                'DB_PASSWORD',
                'SSH_AUTH_SOCK',
                'lowercase_secret',
                'API_CREDENTIAL',
                'UNRELATED_SECRET',
                'OTHER_API_TOKEN',
            ):
                self.assertNotIn(stripped, forwarded)

    def test_reexecs_via_with_secrets_when_manifest_present_and_keys_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            scripts_dir = root / 'scripts'
            scripts_dir.mkdir()
            (root / '.secrets').write_text('DASHSCOPE_API_KEY\nDEEPSEEK_API_KEY\n')
            script = scripts_dir / 'run-with-secrets.py'
            script.write_text(SOURCE.read_text())
            out = root / 'env.json'
            helper = scripts_dir / 'launch-macos.swift'
            helper.write_text(
                'import Foundation\n'
                'let env = ProcessInfo.processInfo.environment\n'
                'let data = try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])\n'
                f'try data.write(to: URL(fileURLWithPath: {json.dumps(str(out))}))\n'
            )
            fake_bin = root / 'bin'
            fake_bin.mkdir()
            fake_ws = fake_bin / 'with-secrets'
            fake_ws.write_text(
                '#!/usr/bin/env python3\n'
                'import os, sys\n'
                'args = sys.argv[1:]\n'
                'sep = args.index("--")\n'
                'opts, cmd = args[:sep], args[sep + 1:]\n'
                f'assert opts == ["--project", {json.dumps(str(root))}, "--optional"], opts\n'
                'env = os.environ.copy()\n'
                'env["DASHSCOPE_API_KEY"] = "from-with-secrets-qwen"\n'
                'env["DEEPSEEK_API_KEY"] = "from-with-secrets-deepseek"\n'
                'env["UNRELATED_SECRET"] = "must-strip"\n'
                'os.execvpe(cmd[0], cmd, env)\n'
            )
            fake_ws.chmod(fake_ws.stat().st_mode | stat.S_IXUSR)

            env = {
                'PATH': f'{fake_bin}:/usr/bin:/bin',
                'HOME': str(root),
            }
            result = subprocess.run(
                ['python3', str(script), 'macos'],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            forwarded = json.loads(out.read_text())
            self.assertEqual(forwarded.get('KOE_CREDENTIAL_SOURCE'), 'environment')
            self.assertEqual(forwarded.get('DASHSCOPE_API_KEY'), 'from-with-secrets-qwen')
            self.assertEqual(forwarded.get('DEEPSEEK_API_KEY'), 'from-with-secrets-deepseek')
            self.assertNotIn('UNRELATED_SECRET', forwarded)
            self.assertNotIn('KOE_WITH_SECRETS_REEXEC', forwarded)


if __name__ == '__main__':
    unittest.main()
