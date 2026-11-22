#!/usr/bin/env python3
"""Run the nine Maestro journeys on a dedicated iPhone simulator or koe-test Android AVD."""
import argparse
import copy
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent


def seed(directory, *, title='行动页测试', speakers=(), root=ROOT):
    library = 'libkoe_host_api.dylib' if sys.platform == 'darwin' else 'libkoe_host_api.so'
    api = ctypes.CDLL(str(Path(root) / 'target/debug' / library))
    api.koe_host_session_create.argtypes = [ctypes.c_char_p]
    api.koe_host_session_create.restype = ctypes.c_uint64
    api.koe_host_session_dispatch_json.argtypes = [ctypes.c_uint64, ctypes.c_char_p, ctypes.c_uint64]
    api.koe_host_session_dispatch_json.restype = ctypes.c_void_p
    api.koe_host_string_free.argtypes = [ctypes.c_void_p]
    api.koe_host_string_free.restype = None
    api.koe_host_session_destroy.argtypes = [ctypes.c_uint64]
    api.koe_host_session_destroy.restype = ctypes.c_bool
    handle = api.koe_host_session_create(str(directory).encode())
    if not handle:
        raise RuntimeError('Failed to open test workspace')

    def send(command, **fields):
        raw = api.koe_host_session_dispatch_json(handle, json.dumps(dict(type=command, **fields)).encode(), 1)
        if not raw:
            raise RuntimeError(command)
        try:
            snapshot = json.loads(ctypes.string_at(raw))
        finally:
            api.koe_host_string_free(raw)
        if snapshot.get('error'):
            raise RuntimeError(snapshot['error'])
        return snapshot

    try:
        detail = send('create_note', title=title, text='核对会议纪要\n整理项目文档')['detail']
        for index, segment in enumerate(detail['segments']):
            if speakers:
                send('set_segment_speaker', recordId=detail['id'], segmentId=segment['id'], speaker=speakers[index])
            for command, collection in [('create_task', 'tasks'), ('save_memory', 'memories')]:
                snapshot = send(command, recordId=detail['id'], segmentId=segment['id'])
                item = next(item for item in snapshot[collection] if item['text'] == segment['text'])
                send('review_item', itemId=item['id'], decision='reset')
        return detail['id']
    finally:
        api.koe_host_session_destroy(handle)


def build_device_fixture(base_fixture, record_id):
    fixture = copy.deepcopy(base_fixture)
    fixture['generation'] = 1_000_000
    fixture['error'] = 'M9 BLE interrupted'
    fixture['playback'].update(asset=None, recordId=None, isPlaying=False, positionMs=0, requestId=0, lanes=[])
    fixture.update(activeCapture=None, liveCaption=None)
    device = fixture['device']
    device.update(recording=False, busy=False, liveRecordId=None, progress=0.42)
    device['files'][0]['downloading'] = True
    device['files'].append(dict(
        id=102, title='M9Synced', durationMs=3000, synced=True, downloading=False, recordId=record_id,
    ))
    device['guide'] = dict(
        mode='onboarding', step=0, totalSteps=3, title='连接录音豆', subtitle='请靠近设备',
        imageName='', highlightTarget='', primaryLabel='下一步',
    )
    fixture['workspaces']['picker']['canReleaseToPhone'] = True
    return fixture


def run_e2e(platform_name, evidence, *, udid=None, apk=None, root=ROOT, seeder=seed, runner=subprocess.run):
    ios = platform_name == 'ios'
    platform_dir = Path(root) / 'platforms' / platform_name
    test_dir = platform_dir / ('Tests' if ios else 'tests')
    flows = test_dir / 'maestro'
    output = Path(evidence).resolve() / platform_name
    output.mkdir(parents=True, exist_ok=False)
    harness = [platform_dir / ('verify-simulator.sh' if ios else 'verify-emulator.sh'), '--slim',
               '--keep-artifacts', '--flow-timeout', '900']
    if ios:
        harness += ['--udid', udid]
    else:
        harness += ['--with-audio', '--apk', Path(apk).resolve(), '--launch-app',
                    '--app-package', 'com.semanticcraft.koe', '--grant-permission', 'android.permission.RECORD_AUDIO']
    runner(['cargo', 'build', '-p', 'koe-host-api'], cwd=root, check=True)
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        if seeder is seed:
            record_id = seed(directory, title='M9Synced', speakers=('Alice', 'Bob'), root=root)
        else:
            record_id = seeder(directory, title='M9Synced', speakers=('Alice', 'Bob'))
        product = directory / 'product-workspace.json'
        workspace = 'journeys-' + uuid.uuid4().hex
        runner([*harness, '--flow', flows / f'e2e-design-purpose-{platform_name}.yaml',
                '--workspace', workspace, '--seed', product, '--restart-flow', flows / 'design-restart.yaml',
                '--artifacts-dir', output / 'live'], check=True)
        base_fixture = json.loads(
            (test_dir / ('Fixtures' if ios else 'fixtures') / f'{platform_name}-rich-snapshot.json').read_text(encoding='utf-8')
        )
        path = directory / 'device.json'
        path.write_text(json.dumps(build_device_fixture(base_fixture, record_id), ensure_ascii=False), encoding='utf-8')
        for phase in ('device', 'device-link'):
            runner([*harness, '--flow', flows / f'design-{phase}.yaml', '--workspace', workspace + '-' + phase,
                    '--seed', product, '--fixture', path, '--artifacts-dir', output / phase], check=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=('ios', 'android'))
    parser.add_argument('evidence', type=Path, help='shared output root for both platforms')
    parser.add_argument('--udid', help='dedicated, exclusively owned iPhone simulator')
    parser.add_argument('--apk', type=Path, help='githubDebug APK with matching Rust native library')
    args = parser.parse_args(argv)
    ios = args.platform == 'ios'
    if ios and not args.udid or not ios and not args.apk:
        parser.error('provide --udid for iOS or --apk for Android')
    run_e2e(args.platform, args.evidence, udid=args.udid, apk=args.apk)


if __name__ == '__main__':
    main()
