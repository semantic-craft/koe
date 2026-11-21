#!/usr/bin/env python3
"""Stage a disposable AVD for a cold boot or a golden snapshot restore."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


def stage(source_home, name, output, *, with_audio=False):
    original = (source_home / (name + '.avd')).resolve()
    clone = output / original.name
    # APFS clones don't duplicate the multi-GB RAM and userdata images.
    flags = ['-cR'] if sys.platform == 'darwin' else ['-a', '--reflink=auto']
    subprocess.run(['cp', *flags, str(original), str(clone)], check=True)
    ini = source_home / (name + '.ini')
    text = re.sub(r'^path=.*$', lambda _: 'path=' + str(clone), ini.read_text(), flags=re.M)
    (output / ini.name).write_text(text)
    config = clone / 'config.ini'
    settings = config.read_text()
    hardware = clone / 'snapshots/avdslim_clean/hardware.ini'
    if hardware.is_file():
        settings = re.sub(r'(?im)^(fastboot\.forceColdBoot\s*=\s*)(yes|true|1)\s*$', r'\g<1>no', settings)
    if with_audio:
        for key in ('hw.audioInput', 'hw.audioOutput'):
            line = f'{key}=yes'
            settings, count = re.subn(rf'(?im)^[ \t]*{re.escape(key)}[ \t]*=.*$', line, settings)
            if not count:
                settings = settings.rstrip('\n') + '\n' + line + '\n'
    config.write_text(settings)
    if not hardware.is_file():
        return
    # Emulator compares the saved launch configuration before restoring RAM.
    # Only update clone-local paths and the boot preference. Keep VM hardware identical.
    lines = []
    for line in hardware.read_text().splitlines():
        key, separator, value = line.partition(' = ')
        if key == 'fastboot.forceColdBoot':
            value = 'false'
        elif value.startswith('/') and Path(os.path.normpath(value)).parent == original:
            value = str(clone / Path(value).name)
        lines.append(key + separator + value)
    hardware.write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_home', type=Path)
    parser.add_argument('name')
    parser.add_argument('output', type=Path)
    parser.add_argument('--with-audio', action='store_true')
    args = parser.parse_args()
    stage(args.source_home, args.name, args.output, with_audio=args.with_audio)
