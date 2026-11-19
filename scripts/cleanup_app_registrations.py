#!/usr/bin/env python3
"""Unregister apps inside one caller-owned disposable tree before deleting it.

Never delete files, reset the database or stop processes. A live executable,
redirected app path or failed registration cleanup retains the caller's tree.
"""
from pathlib import Path
import ctypes
import errno
import fcntl
import os
import pwd
import re
import shutil
import subprocess
import sys
import time
import unicodedata

LSREGISTER = (
    os.environ.get('KOE_LSREGISTER')
    or '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
)
SETTLE_SECONDS = float(os.environ.get('KOE_CLEANUP_SETTLE_SECONDS') or '0.65')

PC_CASE_SENSITIVE = 11
F_GETPATH = 50
F_GETPATH_BUF_SIZE = 1024
RENAME_SWAP = 0x00000002
SYSTEM_ROOT_LINKS = frozenset({Path('/var'), Path('/tmp'), Path('/etc')})


def _is_case_insensitive_volume(path):
    probe = Path(path)
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        return os.pathconf(probe, PC_CASE_SENSITIVE) == 0
    except (OSError, ValueError, AttributeError):
        pass
    cur = probe
    while cur != cur.parent:
        alternate = cur.with_name(cur.name.swapcase())
        if alternate != cur:
            return alternate.exists() and cur.samefile(alternate)
        cur = cur.parent
    return False


def inside(path, root):
    path = Path(path)
    root = Path(root)
    if path == root or root in path.parents:
        return True
    try:
        root_stat = os.stat(root) if root.exists() else None
    except OSError:
        root_stat = None
    if root_stat is not None:
        cur = path
        while len(cur.parts) >= len(root.parts):
            try:
                if cur.exists() and os.path.samestat(os.stat(cur), root_stat):
                    return True
            except OSError:
                pass
            if cur == cur.parent:
                break
            cur = cur.parent
    if _is_case_insensitive_volume(root) or _is_case_insensitive_volume(path):
        parts = tuple(unicodedata.normalize('NFD', part).casefold() for part in path.parts)
        prefix = tuple(unicodedata.normalize('NFD', part).casefold() for part in root.parts)
        return len(parts) >= len(prefix) and parts[:len(prefix)] == prefix
    if sys.platform == 'darwin':
        parts = tuple(unicodedata.normalize('NFD', part) for part in path.parts)
        prefix = tuple(unicodedata.normalize('NFD', part) for part in root.parts)
        return len(parts) >= len(prefix) and parts[:len(prefix)] == prefix
    return False


def _real_disk_path(path):
    missing_tail = []
    existing = Path(path)
    while not os.path.lexists(existing) and existing != existing.parent:
        missing_tail.append(existing.name)
        existing = existing.parent
    resolved = existing.resolve()
    if sys.platform == 'darwin' and resolved.exists():
        try:
            fd = os.open(resolved, os.O_RDONLY)
            try:
                raw = fcntl.fcntl(fd, F_GETPATH, bytes(F_GETPATH_BUF_SIZE)).split(b'\x00', 1)[0]
                if raw:
                    resolved = Path(os.fsdecode(raw))
            finally:
                os.close(fd)
        except OSError:
            pass
    for name in reversed(missing_tail):
        resolved = resolved / name
    return resolved


def resolve_home_dir(home_arg=None):
    raw_home = home_arg if home_arg else pwd.getpwuid(os.getuid()).pw_dir
    if not raw_home or '\x00' in raw_home:
        raise ValueError(f'invalid HOME directory ({raw_home!r})')
    home_path = Path(raw_home)
    if not home_path.is_absolute() or '..' in home_path.parts:
        raise ValueError(f"HOME must be an absolute path without '..' ({raw_home})")
    resolved_home = _real_disk_path(home_path)
    if resolved_home == Path('/'):
        raise ValueError("HOME must not resolve to '/'")
    return resolved_home


def canonicalize_bundle_path(raw_arg, caller_pwd, home_dir, label, allowed_link_prefixes=()):
    if not raw_arg or '\x00' in raw_arg:
        raise ValueError(f'{label} must name a .app bundle ({raw_arg!r})')
    if '..' in Path(raw_arg).parts:
        raise ValueError(f"{label} must not contain '..' ({raw_arg})")
    resolved_home = (
        resolve_home_dir(str(home_dir)) if home_dir is not None else resolve_home_dir(None)
    )
    if raw_arg == '~' or raw_arg.startswith('~/'):
        rel = raw_arg[1:].lstrip('/')
        if rel and '..' in Path(rel).parts:
            raise ValueError(f"{label} must not contain '..' ({raw_arg})")
        candidate = resolved_home / Path(rel) if rel else resolved_home
    elif raw_arg.startswith('~'):
        raise ValueError(f'{label} must not use ~user expansion ({raw_arg})')
    else:
        raw_path = Path(raw_arg)
        if raw_path.is_absolute():
            candidate = raw_path
        else:
            pwd_path = Path(caller_pwd)
            if not pwd_path.is_absolute() or '..' in pwd_path.parts:
                raise ValueError(f'caller working directory must be absolute ({caller_pwd})')
            candidate = pwd_path / raw_path
    if '..' in candidate.parts:
        raise ValueError(f"{label} must not contain '..' ({raw_arg})")
    if not candidate.name.endswith('.app') or len(candidate.name) <= 4:
        raise ValueError(f'{label} must name a .app bundle ({raw_arg})')
    if candidate.is_symlink():
        raise ValueError(f'{label} must not be a symlink ({raw_arg})')
    allowed_links = set(SYSTEM_ROOT_LINKS)
    for prefix in allowed_link_prefixes:
        pref = Path(prefix)
        cur_pref = Path(pref.anchor)
        for part in pref.parts[1:]:
            cur_pref = cur_pref / part
            allowed_links.add(cur_pref)
    cur = Path(candidate.anchor)
    for part in candidate.parts[1:]:
        cur = cur / part
        if cur in allowed_links:
            continue
        if cur.is_symlink():
            raise ValueError(f'{label} must not traverse symlink {cur} ({raw_arg})')
    real_parent = _real_disk_path(candidate.parent)
    leaf = real_parent / candidate.name
    if leaf.is_symlink() or os.path.islink(leaf):
        raise ValueError(f'{label} must not be a symlink ({raw_arg})')
    actual_name = candidate.name
    if leaf.exists():
        matched = None
        if sys.platform == 'darwin':
            try:
                fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    raw = fcntl.fcntl(fd, F_GETPATH, bytes(F_GETPATH_BUF_SIZE)).split(b'\x00', 1)[0]
                    if raw:
                        matched = Path(os.fsdecode(raw)).name
                finally:
                    os.close(fd)
            except OSError:
                matched = None
        if not matched:
            try:
                matched = next(
                    (entry.name for entry in real_parent.iterdir() if entry.samefile(leaf)),
                    candidate.name,
                )
            except OSError:
                matched = candidate.name
        actual_name = matched
    return real_parent / actual_name


def validate_install_paths(target_arg, source_arg, root_arg, caller_pwd_arg, home_arg=None):
    raw_home = home_arg if home_arg else pwd.getpwuid(os.getuid()).pw_dir
    home = resolve_home_dir(home_arg)
    caller_pwd = _real_disk_path(Path(caller_pwd_arg))
    root = _real_disk_path(Path(root_arg))
    allowed_prefixes = (Path(raw_home), Path(caller_pwd_arg), Path(root_arg))
    target = canonicalize_bundle_path(
        target_arg, caller_pwd, home, 'MACOS_INSTALL_PATH', allowed_prefixes
    )
    source = canonicalize_bundle_path(
        source_arg, caller_pwd, home, 'KOE_BUILD_APP', allowed_prefixes
    )
    if inside(target, root) or inside(root, target):
        raise ValueError(f'MACOS_INSTALL_PATH overlaps repository root ({target})')
    if inside(target, source) or inside(source, target):
        raise ValueError(f'MACOS_INSTALL_PATH overlaps KOE_BUILD_APP ({target})')
    sys_root = Path('/')
    sys_apps = _real_disk_path(Path('/Applications'))
    home_apps = _real_disk_path(home / 'Applications')
    sys_system = _real_disk_path(Path('/System'))
    sys_library = _real_disk_path(Path('/Library'))
    for protected in (sys_root, sys_apps, home, home_apps, sys_system, sys_library):
        if inside(protected, target):
            raise ValueError(f'MACOS_INSTALL_PATH cannot equal or contain {protected} ({target})')
        if inside(protected, source):
            raise ValueError(f'KOE_BUILD_APP cannot equal or contain {protected} ({source})')
    if inside(target, sys_system) or inside(target, sys_library):
        raise ValueError(f'unsafe MACOS_INSTALL_PATH inside system tree ({target})')
    if (
        inside(root, source)
        or inside(source, sys_apps)
        or inside(source, home_apps)
        or inside(source, sys_system)
        or inside(source, sys_library)
    ):
        raise ValueError(f'unsafe KOE_BUILD_APP location ({source})')
    return target, source


def registered_apps():
    dump = subprocess.check_output([LSREGISTER, '-dump'], text=True)
    result = []
    for block in re.split(r'\n-{10,}\n', dump):
        if not block.lstrip().startswith('bundle id:'):
            continue
        match = re.search(r'^\s*path:\s+(.+)$', block, re.MULTILINE)
        if match:
            result.append(Path(re.sub(r' \(0x[0-9a-fA-F]+\)$', '', match[1])))
    return result


def running_executables():
    # ps comm can be truncated to 16 characters for CLI-built executables.
    # libproc supplies the kernel executable path without reading arguments.
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    pids = subprocess.check_output(['/bin/ps', '-U', str(os.getuid()), '-o', 'pid='], text=True)
    paths = []
    for value in pids.split():
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(int(value), buffer, len(buffer)) > 0:
            paths.append(Path(os.fsdecode(buffer.value)).resolve())
        elif ctypes.get_errno() not in (errno.ESRCH, errno.ENOENT):
            raise OSError(ctypes.get_errno(), 'Cannot inspect executable; cleanup refused')
    return paths


def has_running_bundle(target_path, app_name='Koe'):
    if sys.platform != 'darwin':
        return False
    target = Path(target_path)
    roots = [target]
    parent = target.parent
    if parent.is_dir():
        prefix = f'.{app_name}.stage.'
        try:
            for entry in parent.iterdir():
                if entry.name.startswith(prefix):
                    roots.append(entry)
        except OSError:
            pass
    for exe in running_executables():
        if any(inside(exe, r) for r in roots):
            return True
    return False


def atomic_swap_or_move(src, dst):
    src_fs = os.fsencode(os.fspath(src))
    dst_fs = os.fsencode(os.fspath(dst))
    if os.path.lexists(dst_fs):
        libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        libc.renamex_np.restype = ctypes.c_int
        if libc.renamex_np(src_fs, dst_fs, RENAME_SWAP) == 0:
            return 'swap'
        err = ctypes.get_errno()
        if err != errno.ENOENT:
            raise OSError(err, os.strerror(err), os.fsdecode(dst_fs))
    os.rename(src_fs, dst_fs)
    return 'new'


def prepare(root):
    """Return only after all scoped registrations are gone; raise to retain files."""
    raw = Path(root).absolute()
    if raw.is_symlink():
        raise RuntimeError(f'Refusing redirected cleanup root ({raw})')
    root = raw.resolve()
    home = resolve_home_dir(os.environ.get('HOME'))
    if (
        any(
            inside(protected, root)
            for protected in (
                Path('/'),
                home,
                Path('/Applications').resolve(),
                (home / 'Applications').resolve(),
                Path('/Library').resolve(),
                Path('/System').resolve(),
            )
        )
        or inside(root, Path('/Applications').resolve())
        or inside(root, (home / 'Applications').resolve())
        or inside(root, Path('/Library/Input Methods'))
        or inside(root, Path('/System').resolve())
    ):
        raise RuntimeError(f'Not a disposable tree ({root})')
    if sys.platform != 'darwin':
        return
    # Executables can have cwd=/ even while their bundle is inside the build tree.
    if any(inside(path, root) for path in running_executables()):
        raise RuntimeError(f'Running executable inside {root}; retained')
    # Read registered paths, including nested helpers and already-deleted products.
    # Do not follow a symlink out of the disposable tree.
    empty_seen = False
    previous_count = None
    stalled = 0
    deadline = time.monotonic() + 120
    while stalled < 8 and time.monotonic() < deadline:
        records = [p for p in registered_apps() if inside(p, root)]
        stalled = 0 if previous_count is None or len(records) < previous_count else stalled + 1
        previous_count = len(records)
        paths = set(records)
        if not paths:
            if any(inside(path, root) for path in running_executables()):
                raise RuntimeError(f'Running executable inside {root}; retained')
            if empty_seen:
                return
            empty_seen = True
            time.sleep(SETTLE_SECONDS)
            continue
        empty_seen = False
        for app in sorted(paths, key=lambda p: len(p.parts), reverse=True):
            if app.resolve() != app or not inside(app.resolve(), root):
                raise RuntimeError(f'Redirected registered path ({app})')
            result = subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True, text=True)
            if result.returncode and '-10814' not in result.stdout + result.stderr:
                raise RuntimeError(f'Unregister failed for {app} ({result.returncode})')
        # Duplicate records can share one path; one -u need not remove them all.
    raise RuntimeError(f'Registration cleanup did not settle in {root}; retained')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--remove':
        target = Path(sys.argv[2])
        prepare(target)
        if target.exists():
            shutil.rmtree(target)
        prepare(target)  # Catch delayed registrations after the last file disappears.
    elif len(sys.argv) == 2:
        prepare(sys.argv[1])
    else:
        raise SystemExit('Usage: cleanup_app_registrations.py [--remove] OWNED_BUILD_TREE')
