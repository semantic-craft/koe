#!/usr/bin/env python3
"""Relocate a golden AVD into a disposable copy, preserving its original disks and snapshot."""
import os
from pathlib import Path
import re
import subprocess
import sys


def stage(source_home, name, output):
    original = (source_home / (name + '.avd')).resolve()
    clone = output / original.name
    # APFS clones don't duplicate the multi-GB RAM and userdata images.
    flags = ['-cR'] if sys.platform == 'darwin' else ['-a', '--reflink=auto']
    subprocess.run(['cp', *flags, str(original), str(clone)], check=True)
    ini = source_home / (name + '.ini')
    text = re.sub(r'^path=.*$', lambda _: 'path=' + str(clone), ini.read_text(), flags=re.M)
    (output / ini.name).write_text(text)
    config = clone / 'config.ini'
    config.write_text(re.sub(r'(?im)^(fastboot\.forceColdBoot\s*=\s*)(yes|true|1)\s*$',
                             r'\g<1>no', config.read_text()))
    hardware = clone / 'snapshots/avdslim_clean/hardware.ini'
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
    stage(Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]))
