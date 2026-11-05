#!/usr/bin/env python3
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

if sys.platform != "darwin":
    raise SystemExit("此预览打包入口仅支持 macOS")
root = Path(__file__).resolve().parents[1]
app = root / "target" / "Koe Preview.app"
contents = app / "Contents"
executable_dir = contents / "MacOS"
for directory in (root / "target", app, contents, executable_dir):
    if directory.is_symlink():
        raise SystemExit(f"拒绝写入符号链接：{directory}")
    directory.mkdir(exist_ok=True)
executable = executable_dir / "koe-desktop"
info = contents / "Info.plist"
for target in (executable, info):
    if target.is_symlink():
        raise SystemExit(f"拒绝写入符号链接：{target}")
subprocess.run(
    [
        "cargo",
        "build",
        "--locked",
        "--manifest-path",
        str(root / "Cargo.toml"),
        "--workspace",
        "--target-dir",
        str(root / "target"),
    ],
    check=True,
)
shutil.copy2(root / "target" / "debug" / "koe-desktop", executable)
os.chmod(executable, 0o755)
info.write_bytes(
    plistlib.dumps(
        {
            "CFBundleIdentifier": "com.semanticcraft.koe.preview",
            "CFBundleName": "Koe Preview",
            "CFBundleDisplayName": "Koe Preview",
            "CFBundleExecutable": "koe-desktop",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "0.1.0",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": True,
        }
    )
)
print(app)
