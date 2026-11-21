#!/usr/bin/env python3
"""Run the nine Maestro journeys on a dedicated iPhone simulator or koe-test Android AVD."""
import argparse
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=('ios', 'android'))
    parser.add_argument('evidence', type=Path, help='shared output root for both platforms')
    parser.add_argument('--udid', help='dedicated, exclusively owned iPhone simulator')
    parser.add_argument('--apk', type=Path, help='githubDebug APK with matching Rust native library')
    args = parser.parse_args()
    ios = args.platform == 'ios'
    if ios and not args.udid or not ios and not args.apk:
        parser.error('provide --udid for iOS or --apk for Android')
    platform = ROOT / 'platforms' / args.platform
    test_dir = platform / ('Tests' if ios else 'tests')
    flows = test_dir / 'maestro'
    output = args.evidence.resolve() / args.platform
    output.mkdir(parents=True, exist_ok=False)
    harness = [platform / ('verify-simulator.sh' if ios else 'verify-emulator.sh'), '--slim',
               '--keep-artifacts', '--flow-timeout', '900']
    if ios:
        harness += ['--udid', args.udid]
    else:
        harness += ['--with-audio', '--apk', args.apk.resolve(), '--launch-app',
                    '--app-package', 'com.semanticcraft.koe', '--grant-permission', 'android.permission.RECORD_AUDIO']
    subprocess.run(['cargo', 'build', '-p', 'koe-host-api'], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        seed = runpy.run_path(str(ROOT / 'platforms/ios/Tests/maestro/test-review-items.py'))['seed']
        record_id = seed(directory, title='M9Synced', speakers=('Alice', 'Bob'))
        product = directory / 'product-workspace.json'
        workspace = 'journeys-' + uuid.uuid4().hex
        subprocess.run([*harness, '--flow', flows / f'e2e-design-purpose-{args.platform}.yaml',
                        '--workspace', workspace, '--seed', product, '--restart-flow', flows / 'design-restart.yaml',
                        '--artifacts-dir', output / 'live'], check=True)
        # Only the radio/transfer state comes from a view fixture. The synced row opens a real Rust record.
        fixture = json.loads((test_dir / ('Fixtures' if ios else 'fixtures') /
                              f'{args.platform}-rich-snapshot.json').read_text())
        fixture['generation'] = 1_000_000
        fixture['error'] = 'M9 BLE interrupted'
        # The general fixture's player points to an absent sample file. Keep the device panel
        # isolated so the native player's error cannot replace the expected BLE message.
        fixture['playback'].update(asset=None, recordId=None, isPlaying=False, positionMs=0, requestId=0, lanes=[])
        fixture.update(activeCapture=None, liveCaption=None)
        device = fixture['device']
        device.update(recording=False, busy=False, liveRecordId=None, progress=0.42)
        device['files'][0]['downloading'] = True
        device['files'].append(dict(id=102, title='M9Synced', durationMs=3000, synced=True,
                                    downloading=False, recordId=record_id))
        device['guide'] = dict(mode='onboarding', step=0, totalSteps=3, title='连接录音豆', subtitle='请靠近设备',
                               imageName='', highlightTarget='', primaryLabel='下一步')
        fixture['workspaces']['picker']['canReleaseToPhone'] = True
        path = directory / 'device.json'
        path.write_text(json.dumps(fixture, ensure_ascii=False))
        for phase in ('device', 'device-link'):
            subprocess.run([*harness, '--flow', flows / f'design-{phase}.yaml', '--workspace', workspace + '-' + phase,
                            '--seed', product, '--fixture', path, '--artifacts-dir', output / phase], check=True)


if __name__ == '__main__':
    main()
