#!/usr/bin/env python3
"""Launch the installed validation build with scoped environment credentials.
Run with `direnv exec . python3 scripts/run-with-secrets.py macos`.
No secrets are printed, embedded in builds, or written to app preferences.
"""
import os
from pathlib import Path
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

provider_keys = {
    name: os.environ[name]
    for name in ('DASHSCOPE_API_KEY', 'DEEPSEEK_API_KEY')
    if os.environ.get(name)
}
if len(sys.argv) == 2 and sys.argv[1] == 'macos':
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

else:
    raise SystemExit('Usage: run-with-secrets.py macos')
