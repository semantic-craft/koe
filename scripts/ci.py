#!/usr/bin/env python3
"""Run the required CI check, with a narrow documentation-only fast path."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
PROGRESS_FILES = {'progress/progress.json', 'progress/index.html'}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def changed_range():
    event = os.environ.get('GITHUB_EVENT_NAME')
    if event not in ('pull_request', 'push'):
        return None
    try:
        payload = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        if event == 'pull_request':
            base = payload['pull_request']['base']['sha']
            head = payload['pull_request']['head']['sha']
        else:
            base, head = payload['before'], payload['after']
        if any(not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{40}', sha)
               or sha == '0' * 40 for sha in (base, head)):
            return None
        git('cat-file', '-e', base + '^{commit}')
        git('cat-file', '-e', head + '^{commit}')
        if event == 'pull_request':
            base = git('merge-base', base, head).decode().strip()
        return base, head
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as exc:
        print(f'Cannot establish changed range; running full checks: {exc}', flush=True)
        return None


def documentation(path):
    name = PurePosixPath(path)
    return path in PROGRESS_FILES or (name.suffix == '.md' and
           (len(name.parts) == 1 or name.parts[0] == 'docs'))


def main():
    os.chdir(ROOT)
    revision_range = changed_range()
    paths = None
    if revision_range:
        try:
            paths = git('diff', '--name-only', '-z', '--no-renames', *revision_range, '--')
            paths = [p.decode('utf-8', errors='surrogateescape') for p in paths.split(b'\0') if p]
        except subprocess.CalledProcessError:
            print('Cannot list changes; running full checks.', flush=True)
    light = bool(paths) and all(documentation(path) for path in paths)
    print(f'CI scope: {"documentation" if light else "full"}', flush=True)
    if revision_range:
        subprocess.run(['git', 'diff', '--check', *revision_range, '--'], check=True)
    if not light or PROGRESS_FILES.intersection(paths):
        subprocess.run([sys.executable, 'progress/progress.py', 'check'], check=True)
    if light:
        return
    expected = os.environ['FLUTTER_VERSION']
    actual = json.loads(subprocess.check_output(['flutter', '--version', '--machine']))['frameworkVersion']
    if actual != expected:
        raise ValueError(f'Runner has Flutter {actual}, CI expects {expected}')
    subprocess.run(['flutter', 'pub', 'get'], check=True)
    subprocess.run(['scripts/check', '--reporter', 'expanded'], check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print(f'CI failed: {exc}', file=sys.stderr)
        sys.exit(1)
