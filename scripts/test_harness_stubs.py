from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def write_exec(root: Path, rel: str, content: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')
    path.chmod(0o755)
    return path


def read_calls(log_path: Path) -> list[list[Any]]:
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding='utf-8').splitlines() if line]


FAKE_JAVA = '''#!/usr/bin/env python3
import sys
sys.stderr.write('openjdk version "17.0.10"\\n')
sys.exit(0)
'''

FAKE_SLIM = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_CALL_LOG'], 'a', encoding='utf-8') as log:
    print(json.dumps(['slim', *sys.argv[1:]]), file=log)
print('{"rss_mb": 256}')
'''

FAKE_EMULATOR = '''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path

log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['emulator', *sys.argv[1:]]) + '\\n')

if os.environ.get('FAKE_AVD_OBSERVATION'):
    home = Path(os.environ['ANDROID_AVD_HOME'])
    name = sys.argv[sys.argv.index('-avd') + 1]
    registry = dict(line.split('=', 1) for line in (home / (name + '.ini')).read_text().splitlines())
    config = Path(registry['path']) / 'config.ini'
    Path(os.environ['FAKE_AVD_OBSERVATION']).write_text(json.dumps([str(config), config.read_text()]))

child = None
child_pid_file = os.environ.get('FAKE_EMU_CHILD_PID_FILE')
if child_pid_file:
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
    Path(child_pid_file).write_text(str(child.pid), encoding='utf-8')

pid_file = os.environ.get('FAKE_EMU_PID_FILE')
if pid_file:
    Path(pid_file).write_text(str(os.getpid()), encoding='utf-8')

def _stop(_signum, _frame):
    if child is not None:
        try:
            child.terminate()
        except OSError:
            pass
    sys.exit(0)

signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)

while True:
    time.sleep(0.1)
'''

FAKE_ADB = '''#!/usr/bin/env python3
import json, os, shlex, signal, sys
from pathlib import Path

args = sys.argv[1:]
log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(['adb', *args]) + '\\n')

sandbox_root = Path(os.environ['FAKE_SANDBOX_ROOT']) if os.environ.get('FAKE_SANDBOX_ROOT') else None
tmp_root = (sandbox_root / 'data_local_tmp') if sandbox_root else None
app_root = (sandbox_root / 'app_sandbox') if sandbox_root else None
if tmp_root is not None and app_root is not None:
    tmp_root.mkdir(parents=True, exist_ok=True)
    app_root.mkdir(parents=True, exist_ok=True)

if args == ['devices']:
    print('List of devices attached')
    extra = os.environ.get('FAKE_ADB_DEVICES', '')
    if extra:
        print(extra)
    stale_file = os.environ.get('FAKE_ADB_STALE_FILE')
    if stale_file and Path(stale_file).exists():
        parts = Path(stale_file).read_text(encoding='utf-8').strip().split()
        if len(parts) == 2 and int(parts[1]) > 0:
            stale_serial, remaining = parts[0], int(parts[1])
            print(f'{stale_serial}\\toffline')
            Path(stale_file).write_text(f'{stale_serial} {remaining - 1}\\n', encoding='utf-8')
    sys.exit(0)

serial = None
rest = args
if len(args) >= 2 and args[0] == '-s':
    serial = args[1]
    rest = args[2:]

if rest == ['get-state']:
    state = os.environ.get('FAKE_ADB_STATE', 'device')
    if state == 'offline':
        sys.stderr.write('error: device offline\\n')
        sys.exit(1)
    print(state)
    sys.exit(0)

if rest == ['emu', 'avd', 'name']:
    avd = os.environ.get('FAKE_EMU_AVD_NAME', 'koe-test-api35')
    if avd == '__FAIL__':
        sys.stderr.write('error: not an emulator\\n')
        sys.exit(1)
    print(f'{avd}\\r')
    print('OK\\r')
    sys.exit(0)

if rest == ['emu', 'kill']:
    if os.environ.get('FAKE_EMU_KILL_FAIL') == '1':
        sys.stderr.write('error: emulator console unreachable\\n')
        sys.exit(1)
    pid_file = os.environ.get('FAKE_EMU_PID_FILE')
    if pid_file and Path(pid_file).exists():
        pid = int(Path(pid_file).read_text(encoding='utf-8').strip())
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    stale_file = os.environ.get('FAKE_ADB_STALE_FILE')
    stale_polls = int(os.environ.get('FAKE_ADB_STALE_POLLS', '0'))
    if stale_file and stale_polls > 0 and serial:
        Path(stale_file).write_text(f'{serial} {stale_polls}\\n', encoding='utf-8')
    print('OK: killing emulator, bye bye')
    sys.exit(0)

if len(rest) >= 2 and rest[0] == 'install':
    print('Success')
    sys.exit(0)

if len(rest) == 3 and rest[0] == 'push' and tmp_root is not None:
    src = Path(rest[1])
    (tmp_root / Path(rest[2]).name).write_bytes(src.read_bytes())
    print('1 file pushed.')
    sys.exit(0)

if rest[:2] == ['exec-out', 'run-as'] and rest[3] == 'cat' and os.environ.get('FAKE_APP_FILES'):
    path = Path(os.environ['FAKE_APP_FILES'], rest[4].removeprefix('files/'))
    sys.stdout.buffer.write(path.read_bytes())
    sys.exit(0)

if rest == ['exec-out', 'screencap', '-p']:
    sys.stdout.buffer.write(b'\\x89PNG\\r\\n\\x1a\\nFAKE_SCREEN_BYTES')
    sys.exit(0)

if len(rest) == 3 and rest[0] == 'pull':
    Path(rest[2]).write_text(
        '<?xml version="1.0" encoding="UTF-8"?><hierarchy rotation="0"><node text="Settings"/></hierarchy>\\n',
        encoding='utf-8',
    )
    sys.exit(0)

if rest and rest[0] == 'logcat':
    if '-b' in rest and 'crash' in rest:
        print('--------- beginning of crash')
        print('11-20 07:30:01.000  100  100 E AndroidRuntime: fake crash entry')
    else:
        print('--------- beginning of main')
        print('11-20 07:30:00.500  100  100 I KoeHarness: fake main log entry')
    sys.exit(0)

if rest and rest[0] == 'shell':
    raw_cmd = ' '.join(rest[1:])
    tokens = shlex.split(raw_cmd)
    if len(tokens) == 2 and tokens[0] == 'getprop':
        props = {
            'sys.boot_completed': os.environ.get('FAKE_BOOT_COMPLETED', '1'),
            'ro.build.version.sdk': os.environ.get('FAKE_API_LEVEL', '35'),
            'ro.product.cpu.abi': os.environ.get('FAKE_ABI', 'arm64-v8a'),
        }
        print(props.get(tokens[1], '') + '\\r')
        sys.exit(0)

    if tokens and tokens[0] == 'date':
        if len(tokens) != 2 or not tokens[1].startswith('+'):
            sys.stderr.write(f'date: bad date {tokens[1:]}\\n')
            sys.exit(1)
        print(os.environ.get('FAKE_DEVICE_TS', '2026-11-20 07:30:00.000') + '\\r')
        sys.exit(0)

    if len(tokens) == 3 and tokens[:2] == ['uiautomator', 'dump']:
        fail_times = int(os.environ.get('FAKE_UIAUTOMATOR_FAIL_TIMES', '0'))
        state_path = os.environ.get('FAKE_UIAUTOMATOR_ATTEMPTS')
        attempts = 1
        if state_path:
            p = Path(state_path)
            attempts = (int(p.read_text(encoding='utf-8')) if p.exists() else 0) + 1
            p.write_text(str(attempts), encoding='utf-8')
        if attempts <= fail_times:
            sys.stderr.write('ERROR: could not get idle state.\\n')
            sys.exit(1)
        print(f'UI hierchary dumped to: {tokens[2]}')
        sys.exit(0)

    if tokens and tokens[0] == 'rm':
        if tmp_root is not None:
            for target in tokens[1:]:
                if target.startswith('/data/local/tmp/'):
                    p = tmp_root / Path(target).name
                    if p.exists():
                        p.unlink()
        sys.exit(0)

    if tokens[:2] == ['am', 'force-stop']:
        sys.exit(0)

    if len(tokens) == 4 and tokens[:2] == ['pm', 'grant']:
        sys.exit(0)

    if tokens[:2] == ['am', 'start']:
        app_files = os.environ.get('FAKE_APP_FILES')
        if app_files and 'koe_workspace' in tokens:
            workspace = tokens[tokens.index('koe_workspace') + 1]
            Path(app_files, 'active-workspace').write_text(workspace, encoding='utf-8')
        trace_payload = os.environ.get('FAKE_HOST_TRACE_JSON', '')
        if app_root is not None and trace_payload:
            trace_file = app_root / 'com.semanticcraft.koe' / 'files' / 'koe-trace.json'
            trace_file.parent.mkdir(parents=True, exist_ok=True)
            trace_file.write_text(trace_payload, encoding='utf-8')
        print('Status: ok')
        sys.exit(0)

    if tokens and tokens[0] == 'run-as':
        if app_root is None:
            sys.exit(0)
        pkg = tokens[1]
        pkg_dir = app_root / pkg
        pkg_dir.mkdir(parents=True, exist_ok=True)
        sub = tokens[2:]

        if sub and sub[0] == 'rm':
            for rel in sub[1:]:
                if not rel.startswith('-'):
                    p = pkg_dir / rel
                    if p.exists():
                        p.unlink()
            sys.exit(0)

        if sub == ['cat', 'files/koe-trace.json']:
            p = pkg_dir / 'files' / 'koe-trace.json'
            if not p.exists():
                sys.stderr.write('cat: files/koe-trace.json: No such file or directory\\n')
                sys.exit(1)
            sys.stdout.write(p.read_text(encoding='utf-8'))
            sys.exit(0)

        if len(sub) >= 3 and sub[:2] == ['sh', '-c']:
            inner = sub[2]
            if 'test -s files/koe-trace.json' in inner:
                p = pkg_dir / 'files' / 'koe-trace.json'
                sys.exit(0 if p.exists() and p.stat().st_size > 0 else 1)
            if 'files/koe-active-fixture.json' in inner and tmp_root is not None:
                src_match = None
                for i, tok in enumerate(tokens):
                    if tok == '<' and i + 1 < len(tokens):
                        src_match = tokens[i + 1]
                        break
                if src_match is None:
                    for part in inner.split():
                        if part.startswith('/data/local/tmp/'):
                            src_match = part.strip('"\\'')
                            break
                if not src_match:
                    sys.stderr.write(f'no staged fixture path found in: {raw_cmd}\\n')
                    sys.exit(1)
                staged = tmp_root / Path(src_match).name
                if not staged.exists():
                    sys.stderr.write(f'missing pushed file: {staged}\\n')
                    sys.exit(1)
                dst = pkg_dir / 'files' / 'koe-active-fixture.json'
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(staged.read_bytes())
                sys.exit(0)

    sys.stderr.write(f'unexpected fake adb shell: {raw_cmd}\\n')
    sys.exit(1)

sys.stderr.write(f'unexpected fake adb args: {args}\\n')
sys.exit(1)
'''

FAKE_MAESTRO = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
log_path = os.environ.get('FAKE_CALL_LOG')
if log_path:
    with open(log_path, 'a', encoding='utf-8') as f:
        f.write(json.dumps([
            'maestro',
            *args,
            {
                'MAESTRO_CLI_NO_ANALYTICS': os.environ.get('MAESTRO_CLI_NO_ANALYTICS'),
                'MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED': os.environ.get(
                    'MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED'
                ),
            },
        ]) + '\\n')

if 'hierarchy' in args:
    print('{"attributes":{"text":"模式选择","accessibilityText":"模式选择"},"children":[]}')
    sys.exit(0)

if '--udid' not in args:
    sys.stderr.write('error: expected --udid flag on maestro test\\n')
    sys.exit(2)

for i, arg in enumerate(args):
    if arg == '--debug-output' and i + 1 < len(args):
        debug_dir = Path(args[i + 1])
        debug_dir.mkdir(parents=True, exist_ok=True)
        (debug_dir / 'maestro.log').write_text('fake maestro debug output\\n', encoding='utf-8')
        if os.environ.get('FAKE_MAESTRO_WRITE_PNG') == '1':
            shot_dir = debug_dir / 'screenshots'
            shot_dir.mkdir(parents=True, exist_ok=True)
            (shot_dir / 'final_screen.png').write_bytes(b'\\x89PNG\\r\\n\\x1a\\nMAESTRO_FALLBACK_SCREEN')

if os.environ.get('FAKE_APP_FILES'):
    files = Path(os.environ['FAKE_APP_FILES'])
    product = files / (files / 'active-workspace').read_text(encoding='utf-8') / 'product-workspace.json'
    if Path(args[-1]).stem == 'restart':
        if json.loads(product.read_text(encoding='utf-8'))['records'][0]['id'] != 'survivor':
            sys.exit(1)
    else:
        product.parent.mkdir(parents=True, exist_ok=True)
        product.write_text(json.dumps({'records': [{'id': 'survivor'}]}), encoding='utf-8')

container_dir = os.environ.get('FAKE_APP_CONTAINER')
if container_dir:
    docs_dir = Path(container_dir) / 'Documents'
    docs_dir.mkdir(parents=True, exist_ok=True)
    if Path(args[-1]).name == 'smoke-ios-live.yaml':
        workspace_dir = Path((Path(container_dir) / 'launched-workspace').read_text(encoding='utf-8'))
        (workspace_dir / 'product-workspace.json').write_text(
            json.dumps({'provider': {'model': 'deepseek-v4-pro'}}), encoding='utf-8'
        )
    trace_file = docs_dir / 'koe-trace.json'
    if not trace_file.exists():
        trace_file.write_text(json.dumps([
            {
                'kind': 'command',
                'name': 'create_note',
                'generation': 2,
                'section': 'today',
                'hasError': False,
                'timestampEpochMs': 1700000001000,
            }
        ]) + '\\n', encoding='utf-8')

sys.exit(int(os.environ.get('FAKE_MAESTRO_EXIT', '0')))
'''
