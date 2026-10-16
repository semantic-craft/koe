#!/usr/bin/env python3
"""Native AXTree regression, with synthetic data and VoiceOver already running.

Builds a separate test entrypoint into the local Debug app. Restore the normal
entrypoint afterwards with `flutter build macos --debug -t lib/main.dart`.
--skip-build repeats the native loop in seconds after the first build.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/macos/Build/Products/Debug/Koe.app/Contents/MacOS/Koe'
EVIDENCE = ROOT / 'build/ui-evidence'
ENV = {k: v for k, v in os.environ.items()
       if k not in ('SONIOX_API_KEY', 'MOSS_API_KEY', 'DASHSCOPE_API_KEY')}


def voiceover_running():
    return subprocess.run(
        ['pgrep', '-f', '/VoiceOver.app/Contents/MacOS/VoiceOver'],
        stdout=subprocess.DEVNULL, check=False,
    ).returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin' or not voiceover_running():
        sys.exit('INCOMPLETE: enable macOS VoiceOver first; framework semantics alone cannot test the native bridge.')
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        with (EVIDENCE / 'ax-build.log').open('w') as log:
            result = subprocess.run(
                ['flutter', 'build', 'macos', '--debug', '-t',
                 'test/support/macos_accessibility_app.dart'],
                cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT,
                check=False,
            )
        if result.returncode:
            sys.exit('FAIL: native fixture build; see build/ui-evidence/ax-build.log')
    try:
        result = subprocess.run([str(APP)], cwd=ROOT, env=ENV, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=30, check=False)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b''
        if isinstance(output, bytes):
            output = output.decode(errors='replace')
        (EVIDENCE / 'ax-native.log').write_text(output)
        sys.exit('FAIL: fixture timed out; see build/ui-evidence/ax-native.log')
    (EVIDENCE / 'ax-native.log').write_text(result.stdout)
    errors = [line for line in result.stdout.splitlines()
              if 'Failed to update ui::AXTree' in line]
    steps = result.stdout.count('AX_SMOKE_STEP:')
    completed = 'AX_SMOKE_COMPLETED' in result.stdout
    print(f'Native steps: {steps}; AXTree update errors: {len(errors)}; completed: {completed}')
    for line in errors[:3]:
        print(line)
    if (result.returncode or errors or not completed or steps != 9
            or not voiceover_running()):
        sys.exit(1)
    print('PASS: native AXTree update regression. VoiceOver navigation/reading still requires manual validation.')


if __name__ == '__main__':
    main()
