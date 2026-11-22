#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest


SOURCE = Path(__file__).with_name('ci.py')
WORKSPACE_CARGO_TOML = Path(__file__).resolve().parent.parent / 'Cargo.toml'


def check_release_panic_unwind(cargo_toml_path: Path) -> None:
    data = tomllib.loads(cargo_toml_path.read_text(encoding='utf-8'))
    release = data.get('profile', {}).get('release', {})
    panic_mode = release.get('panic') if isinstance(release, dict) else None
    if panic_mode != 'unwind':
        raise ValueError(
            f'{cargo_toml_path}: [profile.release] panic is {panic_mode!r}, '
            'which breaks koe-host-api std::panic::catch_unwind across the C ABI boundary; '
            'set panic = "unwind" under [profile.release] in Cargo.toml'
        )


class CiRoutingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'CI test')
        self.write('README.md', 'Initial\n')
        self.write('crates/koe-engine/src/lib.rs', 'pub fn init() {}\n')
        self.base = self.commit()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls.jsonl'
        stub = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CI_TEST_LOG'], 'a') as log:
    log.write(json.dumps([os.path.basename(sys.argv[0]), *sys.argv[1:]]) + '\\n')
sys.exit(int(os.environ.get('CI_TEST_EXIT', '0')))
'''
        for relative in ('bin/cargo', 'scripts/check', 'progress/progress.py'):
            self.write(relative, stub)
            (self.root / relative).chmod(0o755)
        self.write('scripts/ci.py', SOURCE.read_text())
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        CI_TEST_LOG=str(self.log))

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self, *paths):
        self.git('add', '--', *(paths or ('README.md', 'crates/koe-engine/src/lib.rs')))
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def run_ci(self, event, payload, **env):
        event_file = self.root / 'event.json'
        event_file.write_text(json.dumps(payload))
        result = subprocess.run(
            ['python3', 'scripts/ci.py'], cwd=self.root,
            env=dict(self.env, GITHUB_EVENT_NAME=event, GITHUB_EVENT_PATH=str(event_file), **env),
            capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def push(self, head, **env):
        return self.run_ci('push', {'before': self.base, 'after': head}, **env)

    def assert_full(self, result, calls):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [['progress.py', 'check'], ['cargo', '--version'],
                                ['check']])

    def test_document_only_skips_rust(self):
        self.write('docs/guide with spaces.md', '# Guide\n')
        result, calls = self.push(self.commit('docs/guide with spaces.md'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_progress_runs_generator_check_and_propagates_failure(self):
        self.write('progress/progress.json', '{}\n')
        result, calls = self.push(self.commit('progress/progress.json'), CI_TEST_EXIT='7')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [['progress.py', 'check']])

    def test_progress_success_skips_rust(self):
        self.write('progress/index.html', '<html></html>\n')
        result, calls = self.push(self.commit('progress/index.html'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [['progress.py', 'check']])

    def test_unknown_markdown_path_and_empty_range_run_full(self):
        self.assert_full(*self.push(self.base))
        self.log.unlink()
        self.write('crates/koe-engine/template.md', 'App resource\n')
        self.assert_full(*self.push(self.commit('crates/koe-engine/template.md')))

    def test_mixed_progress_and_workflow_runs_full(self):
        self.write('progress/progress.json', '{}\n')
        self.write('.github/workflows/ci.yml', 'jobs: {}\n')
        self.assert_full(*self.push(self.commit('progress/progress.json', '.github/workflows/ci.yml')))

    def test_code_anywhere_in_push_runs_full(self):
        self.write('crates/koe-engine/src/lib.rs', 'pub fn changed() {}\n')
        self.commit('crates/koe-engine/src/lib.rs')
        self.write('README.md', 'Document change\n')
        self.assert_full(*self.push(self.commit('README.md')))

    def test_progress_runtime_is_code(self):
        self.assert_full(*self.push(self.commit('progress/progress.py')))

    def test_rename_from_code_to_doc_runs_full(self):
        self.git('mv', 'crates/koe-engine/src/lib.rs', 'docs.md')
        self.assert_full(*self.push(self.commit('docs.md')))

    def test_deleted_code_runs_full(self):
        self.git('rm', 'crates/koe-engine/src/lib.rs')
        self.assert_full(*self.push(self.commit('README.md')))

    def test_pull_request_uses_merge_base(self):
        self.write('README.md', 'PR docs\n')
        head = self.commit('README.md')
        self.git('checkout', '-qb', 'base-update', self.base)
        self.write('crates/koe-engine/src/lib.rs', 'pub fn base_only() {}\n')
        base = self.commit('crates/koe-engine/src/lib.rs')
        self.git('checkout', '-q', head)
        result, calls = self.run_ci('pull_request', {'pull_request': {
            'base': {'sha': base}, 'head': {'sha': head}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_manual_and_unknown_base_run_full(self):
        self.assert_full(*self.run_ci('workflow_dispatch', {}))
        self.log.unlink()
        self.assert_full(*self.run_ci('push', {'before': '0' * 40, 'after': self.base}))

    def test_whitespace_failure_stops_light_job(self):
        self.write('README.md', 'Trailing spaces   \n')
        result, calls = self.push(self.commit('README.md'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


class ReleaseProfileContractTest(unittest.TestCase):
    def test_rejects_panic_abort_and_missing_panic_unwind(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, content in (
                ('abort.toml', '[profile.release]\nopt-level = 3\npanic = "abort"\n'),
                ('missing_key.toml', '[profile.release]\nopt-level = 3\n'),
                ('missing_section.toml', '[workspace]\nmembers = []\n'),
            ):
                manifest = root / name
                manifest.write_text(content, encoding='utf-8')
                with self.assertRaises(ValueError) as ctx:
                    check_release_panic_unwind(manifest)
                message = str(ctx.exception)
                self.assertIn('koe-host-api', message)
                self.assertIn('std::panic::catch_unwind', message)
                self.assertIn('set panic = "unwind" under [profile.release] in Cargo.toml', message)

    def test_workspace_cargo_toml_uses_panic_unwind(self):
        check_release_panic_unwind(WORKSPACE_CARGO_TOML)


if __name__ == '__main__':
    unittest.main()
