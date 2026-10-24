#!/usr/bin/env python3
"""Launch the installed validation build with scoped environment credentials.
Run with `direnv exec . python3 scripts/run-with-secrets.py macos`.
No secrets are printed, embedded in builds, or written to app preferences.
"""
import os
from pathlib import Path
import subprocess
import sys

speech = {name: os.environ[name] for name in ('DASHSCOPE_API_KEY', 'DOUBAO_API_KEY') if os.environ.get(name)}
if 'DOUBAO_API_KEY' not in speech and os.environ.get('DOUBAO_TTS_API_KEY'):
    speech['DOUBAO_API_KEY'] = os.environ['DOUBAO_TTS_API_KEY']
if len(sys.argv) == 2 and sys.argv[1] == 'macos':
    environment = {k: v for k, v in os.environ.items() if not any(x in k for x in ('KEY', 'TOKEN', 'SECRET'))}
    environment.update(speech)
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
