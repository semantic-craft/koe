#!/usr/bin/env python3
"""Launch the installed validation build with scoped environment credentials.
Run directly via `python3 scripts/run-with-secrets.py macos` (auto-invokes
`with-secrets` against the repo `.secrets` manifest) or explicitly via
`with-secrets -- python3 scripts/run-with-secrets.py macos`.
No secrets are printed, embedded in builds, or written to app preferences.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys

ALLOWED_ENV_KEYS = (
    'PATH',
    'HOME',
    'USER',
    'LOGNAME',
    'SHELL',
    'TMPDIR',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
    '__CF_USER_TEXT_ENCODING',
    'XPC_FLAGS',
    'XPC_SERVICE_NAME',
)
PROVIDER_KEY_NAMES = ('DASHSCOPE_API_KEY', 'DEEPSEEK_API_KEY')


def _find_with_secrets() -> str | None:
    found = shutil.which('with-secrets')
    if found:
        return found
    fallback = Path.home() / '.local' / 'bin' / 'with-secrets'
    if fallback.is_file() and os.access(fallback, os.X_OK):
        return str(fallback)
    return None


def _reexec_with_secrets_if_needed() -> None:
    if os.environ.get('KOE_WITH_SECRETS_REEXEC'):
        return
    if all(os.environ.get(name) for name in PROVIDER_KEY_NAMES):
        return
    repo_root = Path(__file__).resolve().parent.parent
    if not (repo_root / '.secrets').is_file():
        return
    with_secrets = _find_with_secrets()
    if not with_secrets:
        return
    env = os.environ.copy()
    env['KOE_WITH_SECRETS_REEXEC'] = '1'
    os.execvpe(
        with_secrets,
        [
            with_secrets,
            '--project',
            str(repo_root),
            '--optional',
            '--',
            sys.executable,
            str(Path(__file__).resolve()),
            *sys.argv[1:],
        ],
        env,
    )


if len(sys.argv) != 2 or sys.argv[1] != 'macos':
    raise SystemExit('Usage: run-with-secrets.py macos')

_reexec_with_secrets_if_needed()

provider_keys = {
    name: os.environ[name]
    for name in PROVIDER_KEY_NAMES
    if os.environ.get(name)
}
environment = {k: os.environ[k] for k in ALLOWED_ENV_KEYS if k in os.environ}
environment.update(provider_keys)
environment["KOE_CREDENTIAL_SOURCE"] = "environment"
# LaunchServices gives Koe its own privacy-permission identity. Executing
# Contents/MacOS/Koe directly can inherit the agent's denied EventKit access.
# The native helper passes credentials in memory, never as command arguments.
helper = Path(__file__).with_name('launch-macos.swift')
completed = subprocess.run(['/usr/bin/swift', str(helper)], env=environment,
                           stdin=subprocess.DEVNULL, check=False)
raise SystemExit(completed.returncode)
