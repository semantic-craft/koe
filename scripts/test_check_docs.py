#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_docs import check  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent


class DocsCheckTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding='utf-8')

    def test_reports_missing_targets_in_root_docs_and_github(self):
        self.write('README.md', '# Project\n[missing](gone.md#section)\n')
        self.write('docs/nested/guide.md', '[missing](../absent/)\n')
        self.write('.github/PULL_REQUEST_TEMPLATE.md', '[missing](../missing.md)\n')

        problems = check(self.root)
        self.assertEqual(len(problems), 3, problems)
        for location, target in (
            ('README.md:2', 'gone.md#section'),
            ('docs/nested/guide.md:1', '../absent/'),
            ('.github/PULL_REQUEST_TEMPLATE.md:1', '../missing.md'),
        ):
            self.assertTrue(any(location in problem and target in problem for problem in problems), problems)

    def test_resolves_files_directories_anchors_titles_and_escaped_paths(self):
        self.write('docs/actual (v2).md', '# Section\n')
        self.write('README.md', r'''
[anchor](#section) [http](http://example.invalid) [https](https://example.invalid)
[email](mailto:maintainer@example.invalid) [history](ae0cfa5^:lessons.md)
[folder](docs/) [relative [label]](<docs/actual (v2).md#section> "Title")
[`file`](docs/actual%20(v2).md?plain=1#section)
[escaped](docs/actual%20\(v2\).md)
''')

        self.assertEqual(check(self.root), [])

    def test_link_examples_are_ignored_and_multiline_links_are_checked(self):
        self.write('README.md', '''`[syntax](path)`
~~~markdown
[example](other.md)
~~~
[real](
  target.md "title"
)
''')

        problems = check(self.root)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn('README.md:5', problems[0])
        self.assertIn('target.md', problems[0])

    def test_old_symbols_are_rejected_in_live_documents(self):
        for path, symbol in (
            ('README.md', 'KoeAppleSharedTests'),
            ('docs/ARCHITECTURE.md', 'crates/koe-runtime/src/legacy.rs'),
            ('docs/material-pack.md', 'tests/fixtures/flutter'),
            ('docs/mode-workspaces.md', 'legacy_restore'),
            ('docs/agents/review.md', 'KoeAppleShared'),
        ):
            self.write(path, f'使用 `{symbol}`。\n')

        problems = check(self.root)
        self.assertEqual(len(problems), 5, problems)
        self.assertTrue(all(':1:' in problem for problem in problems), problems)

    def test_legacy_exemptions_are_local_to_archive_notes_and_historical_files(self):
        self.write('docs/agents/lessons.md', '`legacy_restore` 已归档。请运行 `KoeAppleSharedTests`。\n')
        self.write('docs/releases/v1.md', '运行 `legacy_restore`。[原始记录](missing.md)\n')
        self.write('docs/adr/0001.md', '采用 `KoeAppleShared`。\n')

        problems = check(self.root)
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any('lessons.md:1' in problem and 'KoeAppleShared' in problem for problem in problems))
        self.assertTrue(any('v1.md:1' in problem and 'missing.md' in problem for problem in problems))

    def test_worktree_passes_command_line_gate(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / 'scripts/check_docs.py')], cwd=ROOT / 'docs',
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
