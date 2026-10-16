#!/usr/bin/env python3
"""Credential-isolation and signed-upgrade checks for the koe macOS app.

Every mode writes its logs plus result.json into the evidence directory and
never reads, writes or prints a real user credential: the native checks use a
synthetic service, and the app check only inspects process-local state.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')
INSTALLED = Path('/Applications/Koe.app')
LEGACY_INSTALLED = Path('/Applications/Soundcore Manager.app')
RELEASE = ROOT / 'build/macos/Build/Products/Release/Koe.app'
DEBUG = ROOT / 'build/macos/Build/Products/Debug/Koe.app'


def run(args, log=None, env=None, timeout=300):
    process = subprocess.Popen([str(a) for a in args], cwd=ROOT, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        if log:
            log.write_bytes(output)
        raise
    if log:
        log.write_bytes(output)
    if process.returncode:
        raise RuntimeError(f'Check failed ({process.returncode}); see {log}')
    return output


def expect_failure(args, log, env, timeout):
    """A rebuilt binary must fail fast instead of blocking on a password dialog.

    Returns how long the failure took. A blocked read is the reported symptom:
    macOS asking for the login keychain password on every rebuild.
    """
    started = time.monotonic()
    process = subprocess.Popen([str(a) for a in args], cwd=ROOT, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        log.write_bytes(output)
        raise RuntimeError(f'Blocked on the keychain authorization dialog; see {log}')
    log.write_bytes(output)
    if process.returncode == 0:
        raise RuntimeError(f'The rebuilt binary kept keychain access; see {log}')
    return round(time.monotonic() - started, 2)


def clean_env():
    """Child processes inherit no credentials and no developer mode override."""
    return {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in os.environ}


def identity(team):
    found = [line.strip() for line in subprocess.check_output(
        ['security', 'find-identity', '-v', '-p', 'codesigning'], text=True).splitlines()
        if f'({team})' in line and 'Developer ID Application' in line]
    names = [line.split('"')[1] for line in found]
    if len(names) != 1:
        raise RuntimeError(f'Expected one Developer ID Application certificate for {team}, found {len(names)}')
    return names[0]


def requirement_of(app):
    return subprocess.check_output(['codesign', '-d', '-r-', str(app)],
                                   stderr=subprocess.STDOUT, text=True).split('designated => ')[-1].strip()


def cdhash_of(app):
    """Only `codesign -dvvv` prints CDHash; `-dv` stops before it for bundles."""
    output = subprocess.check_output(['codesign', '-dvvv', str(app)],
                                     stderr=subprocess.STDOUT, text=True)
    lines = [line.split('=', 1)[1] for line in output.splitlines()
             if line.startswith('CDHash=')]
    if len(lines) != 1:
        raise RuntimeError(f'Expected one CDHash for {app}, found {len(lines)}')
    return lines[0]


def running(pattern):
    return subprocess.check_output(['pgrep', '-fl', pattern], text=True).splitlines()


def authorization_agent():
    """SecurityAgent runs while a keychain password dialog is on screen."""
    return subprocess.run(['pgrep', '-x', 'SecurityAgent'],
                          stdout=subprocess.DEVNULL).returncode == 0


def doctor(args):
    report = {'mode': 'doctor', 'installed': {}, 'release_build': RELEASE.is_dir(),
              'debug_build': DEBUG.is_dir(), 'passed': False}
    if INSTALLED.is_dir():
        report['installed'] = {'requirement': requirement_of(INSTALLED),
                               'cdhash': cdhash_of(INSTALLED)}
        try:
            report['identity'] = identity(args.team)
        except RuntimeError as error:
            report['identity_error'] = str(error)
    # A leftover pre-rename bundle shares the Bundle ID and can be launched instead.
    report['legacy_installed'] = LEGACY_INSTALLED.exists()
    report['running'] = running('MacOS/Koe$|Soundcore Manager|koe-credentials')
    report['keychain_services'] = subprocess.run(
        ['security', 'find-generic-password', '-s', 'com.semanticcraft.soundcore.credentials'],
        capture_output=True, text=True).returncode == 0
    report['passed'] = report['release_build'] or report['debug_build'] or INSTALLED.is_dir()
    print(json.dumps(report, indent=2))
    if not report['passed']:
        raise RuntimeError('No build or install to verify; run scripts/install-macos.sh first')
    return report


def native(evidence, team):
    record = {'mode': 'native', 'passed': False}
    verifier = evidence
    binaries_dir = evidence / 'bin'
    binaries_dir.mkdir()
    for name, flags in (('debug', ['-D', 'DEBUG']), ('release-adhoc', [])):
        binary = binaries_dir / name
        run(['swiftc', *flags, 'darwin/KeychainStore.swift',
             'test/native/credential_isolation.swift', '-o', binary],
            verifier / f'{name}-compile.log')
        # The spy aborts the process if any Security entry point is reached.
        for mode in ('absent', '', 'environment', 'invalid', 'system'):
            child = clean_env()
            if mode:
                child['KOE_CREDENTIAL_SOURCE'] = mode
            run([binary], verifier / f'{name}-{mode or "absent"}.log', child, 60)
    service = 'com.semanticcraft.koe.validation.' + str(uuid.uuid4())
    binaries = []
    try:
        for name, flags in (('a', []), ('b', ['-D', 'UPGRADE_SECOND'])):
            binary = binaries_dir / f'upgrade-{name}'
            run(['swiftc', *flags, 'darwin/KeychainStore.swift',
                 'test/native/keychain_upgrade.swift', '-o', binary],
                verifier / f'upgrade-{name}-compile.log')
            run(['codesign', '--force', '--sign', identity(team), '--identifier',
                 'com.semanticcraft.koe.validation.upgrade', '--options', 'runtime',
                 '--timestamp=none', binary], verifier / f'upgrade-{name}-sign.log')
            binaries.append(binary)
        record['sha256'] = [hashlib.sha256(b.read_bytes()).hexdigest() for b in binaries]
        if len(set(record['sha256'])) != 2:
            raise RuntimeError('Builds are identical; the upgrade check proves nothing')
        # Build A writes, the rebuilt B reads back, then A still reads after B wrote.
        for index, (build, action) in enumerate([(0, 'write'), (0, 'read'), (1, 'read'), (1, 'write'), (0, 'read')]):
            run([binaries[build], action, service], verifier / f'upgrade-{index}-{action}.log', clean_env(), 30)
        # Control: an ad-hoc rebuild has a different identity, so the item it
        # wrote is no longer readable. It must fail fast rather than leave the
        # user staring at a keychain password dialog.
        control = 'com.semanticcraft.koe.validation.adhoc.' + str(uuid.uuid4())
        first, second = binaries_dir / 'adhoc-first', binaries_dir / 'adhoc-second'
        for name, marker in ((first, 'BUILD_FIRST'), (second, 'BUILD_SECOND')):
            run(['swiftc', '-D', marker, 'darwin/KeychainStore.swift',
                 'test/native/keychain_upgrade.swift', '-o', name], verifier / f'{name.name}-compile.log')
        record['adhoc_sha256'] = [hashlib.sha256(b.read_bytes()).hexdigest() for b in (first, second)]
        if len(set(record['adhoc_sha256'])) != 2:
            raise RuntimeError('Ad-hoc control builds are identical; the check proves nothing')
        record['security_agent_before'] = authorization_agent()
        run([first, 'write', control], verifier / 'adhoc-write.log', clean_env(), 30)
        try:
            run([first, 'read', control], verifier / 'adhoc-owner-read.log', clean_env(), 30)
            record['adhoc_block_seconds'] = expect_failure(
                [second, 'read', control], verifier / 'adhoc-rebuild-read.log', clean_env(), 30)
        finally:
            run([first, 'delete', control], verifier / 'adhoc-cleanup.log', clean_env(), 30)
        # The reported symptom is a password dialog, not just a slow read. A fast
        # failure that still summons the authorization agent is not the fix.
        time.sleep(2)
        record['security_agent_after'] = authorization_agent()
        if record['security_agent_after'] and not record['security_agent_before']:
            raise RuntimeError('The rebuilt binary raised a keychain authorization dialog')
    finally:
        run([binaries[0], 'delete', service], verifier / 'keychain-cleanup.log', clean_env(), 30)
    shutil.rmtree(binaries_dir, ignore_errors=True)
    record['temporary_binaries_removed'] = not binaries_dir.exists()
    record['passed'] = True
    return record


def isolated_app(evidence):
    record = {'mode': 'isolated-app', 'passed': False}
    # The fixture entrypoint replaces the shared Debug build; it is removed
    # again below so no verification app survives the run.
    record['debug_build_replaced'] = DEBUG.exists()
    scratch = Path(tempfile.mkdtemp(prefix='koe-verify-'))
    try:
        if DEBUG.exists():
            shutil.rmtree(DEBUG)
        run(['flutter', 'build', 'macos', '--debug', '-t',
             'test/support/credential_isolation_app.dart'], evidence / 'build.log', clean_env(), 900)
        app = scratch / 'KoeCredentialVerification.app'
        shutil.copytree(DEBUG, app, symlinks=True)
        binary = app / 'Contents/MacOS/Koe'
        for index in range(2):
            output = run([binary], evidence / f'run-{index}.log', clean_env(), 60)
            if b'KOE_CREDENTIAL_ISOLATION_PASS' not in output:
                raise RuntimeError('Isolated app check did not pass')
            record[f'run_{index}'] = output.decode().strip()
    finally:
        for app in scratch.glob('*.app'):
            subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True)
        shutil.rmtree(scratch, ignore_errors=True)
        if DEBUG.exists():
            subprocess.run([LSREGISTER, '-u', str(DEBUG)], capture_output=True)
            shutil.rmtree(DEBUG, ignore_errors=True)
        record['temporary_apps_removed'] = not scratch.exists() and not DEBUG.exists()
    record['passed'] = True
    print('Rebuild the normal Debug app with: flutter build macos --debug -t lib/main.dart')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['doctor', 'native', 'isolated-app'])
    parser.add_argument('--evidence', type=Path,
                        default=ROOT / 'build/verify-koe' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    parser.add_argument('--team', default=os.environ.get('TEAM_ID', 'LQAVR62TK2'))
    args = parser.parse_args()
    if args.mode == 'doctor':
        doctor(args)
        return
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    record = native(evidence, args.team) if args.mode == 'native' else isolated_app(evidence)
    (evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f'FAIL: {error}')
