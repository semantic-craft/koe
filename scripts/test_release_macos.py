#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent
RELEASE_SCRIPT = REPO_ROOT / "scripts" / "release-macos.sh"
CACHE_ROOT = Path(
    subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip()
).resolve()
REAL_LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
)
FORBIDDEN_NOTARY_PROFILE_RE = re.compile(
    r"(?<![a-z0-9])(?!xw-notary(?![a-z0-9-])|macos-notary(?![a-z0-9-]))[a-z0-9][a-z0-9-]*-notary(?![a-z0-9-])",
    re.IGNORECASE,
)

STUB_INSTALL_SCRIPT = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import sys

log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["install-macos.sh", os.environ.get("MACOS_INSTALL_PATH", ""), *sys.argv[1:]]) + "\n")

target = Path(os.environ["MACOS_INSTALL_PATH"])
(target / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
(target / "Contents" / "Resources").mkdir(parents=True, exist_ok=True)
(target / "Contents" / "Frameworks").mkdir(parents=True, exist_ok=True)
(target / "Contents" / "Frameworks" / "libmock.dylib").write_bytes(b"dylib")
(target / "Contents" / "Resources" / "AppIcon.icns").write_bytes(b"icns")
with open(target / "Contents" / "Info.plist", "wb") as fh:
    plistlib.dump(
        {
            "CFBundleExecutable": "Koe",
            "CFBundleIdentifier": "com.anker.ankerRecorder",
            "CFBundleName": "Koe",
            "CFBundleShortVersionString": "2.2.0",
            "CFBundleVersion": "11",
        },
        fh,
    )

exe = target / "Contents" / "MacOS" / "Koe"
exe.write_text(
    '''#!/usr/bin/env python3
import json, os, sys
log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["koe", sys.argv[0], *sys.argv[1:]]) + "\\n")
if len(sys.argv) < 2 or sys.argv[1] not in ("--verify-self", "--smoke-test"):
    raise SystemExit(2)
''',
    encoding="utf-8",
)
exe.chmod(0o755)
"""

STUB_SIGN_SCRIPT = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["sign-macos.sh", *sys.argv[1:]]) + "\\n")

args = sys.argv[1:]
app = Path(args[-1])
if not app.is_dir():
    sys.stderr.write(f"missing app: {app}\\n")
    raise SystemExit(1)
if "--verify-only" in args and os.environ.get("KOE_TEST_FAIL_VERIFY") == "1":
    sys.stderr.write("simulated sign-macos verify-only failure\\n")
    raise SystemExit(1)
"""

STUB_CODESIGN_BIN = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["codesign", *args]) + "\\n")

target = Path(args[-1])
marker = target / "Contents" / ".stub_resigned" if target.suffix == ".app" else target.with_suffix(".resigned")

if "--sign" in args:
    if target.suffix == ".app":
        marker.write_text("1", encoding="utf-8")
    raise SystemExit(0)

if "-r-" in args:
    if os.environ.get("KOE_TEST_MUTATE_DR") == "1" and marker.exists():
        sys.stderr.write(
            'Executable=' + str(target) + '\\n'
            'designated => identifier "com.mutated.app" and anchor apple generic\\n'
        )
    else:
        sys.stderr.write(
            'Executable=' + str(target) + '\\n'
            'designated => identifier "com.anker.ankerRecorder" and anchor apple generic and certificate leaf[subject.OU] = LQAVR62TK2\\n'
        )
    raise SystemExit(0)

if "-dvvv" in args:
    if os.environ.get("KOE_TEST_ADHOC") == "1":
        sys.stderr.write("Signature=adhoc\\nCodeDirectory v=20500 flags=0x0(none)\\n")
        raise SystemExit(0)
    ts_line = "Signed Time=Nov 17, 2026 at 8:28:31 AM\\n" if os.environ.get("KOE_TEST_NO_TIMESTAMP") == "1" else "Timestamp=Nov 17, 2026 at 8:30:00 AM\\n"
    if os.environ.get("KOE_TEST_EXPLICIT_TIMESTAMP_NONE") == "1":
        ts_line = "Timestamp=none\\n"
    sys.stderr.write(
        "Identifier=com.anker.ankerRecorder\\n"
        "CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+0\\n"
        "Authority=Developer ID Application: Test User (LQAVR62TK2)\\n"
        + ts_line
    )
    raise SystemExit(0)

if "--entitlements" in args:
    if os.environ.get("KOE_TEST_DROP_ENTITLEMENTS") == "1":
        sys.stdout.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>\\n')
    else:
        ent_path = Path(os.environ["KOE_TEST_ENTITLEMENTS"])
        sys.stdout.write(ent_path.read_text(encoding="utf-8"))
    raise SystemExit(0)
"""

STUB_SECURITY_BIN = """#!/usr/bin/env python3
print('  1) DEADBEEF00000000000000000000000000000001 "Developer ID Application: Test User (LQAVR62TK2)"')
print('     1 valid identities found')
"""

STUB_MACOS_NOTARY = """#!/usr/bin/env python3
import json
import os
import sys

log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["macos-notary", *sys.argv[1:]]) + "\\n")

if os.environ.get("KOE_TEST_FAIL_NOTARY") == "1":
    sys.stderr.write("simulated macos-notary failure\\n")
    raise SystemExit(1)

print(json.dumps({"notary_status": "Accepted", "submission_id": "stub-id"}))
"""

STUB_MACOS_NOTARY_PROFILE = """#!/usr/bin/env python3
import os
print(os.environ.get("KOE_TEST_PROFILE_CMD_VALUE", "team-profile"))
"""

STUB_LSREGISTER = """#!/usr/bin/env python3
import json
import os
import sys

log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["lsregister", *sys.argv[1:]]) + "\\n")
"""

TRAP_NOTARYTOOL = """#!/usr/bin/env python3
import json
import os
import sys

log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["notarytool", *sys.argv[1:]]) + "\\n")
sys.stderr.write("raw notarytool must not be invoked\\n")
raise SystemExit(99)
"""

TRAP_XCRUN = """#!/usr/bin/env python3
import json
import os
import subprocess
import sys

if len(sys.argv) > 1 and sys.argv[1] == "notarytool":
    log_path = os.environ.get("KOE_SPY_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(["xcrun", *sys.argv[1:]]) + "\\n")
    sys.stderr.write("raw xcrun notarytool must not be invoked\\n")
    raise SystemExit(99)

res = subprocess.run(["/usr/bin/xcrun", *sys.argv[1:]])
raise SystemExit(res.returncode)
"""


class ReleaseMacosScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.sandbox = Path(tempfile.mkdtemp(prefix="koe-release-test-", dir=CACHE_ROOT)).resolve()
        (self.sandbox / ".metadata_never_index").write_bytes(b"")
        self.temp_dir = self.sandbox / "tmp"
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        self.output_dir = self.sandbox / "dist"
        self.spy_log = self.sandbox / "spy.jsonl"

        self.bin_dir = self.sandbox / "bin"
        self.profile_bin_dir = self.sandbox / "profile_bin"
        self.install_script = self.bin_dir / "install-macos.sh"
        self.sign_script = self.bin_dir / "sign-macos.sh"
        self.codesign_bin = self.bin_dir / "codesign"
        self.security_bin = self.bin_dir / "security"
        self.notary_bin = self.bin_dir / "macos-notary"
        self.lsregister_bin = self.bin_dir / "lsregister"

        self._write_executable(self.install_script, STUB_INSTALL_SCRIPT)
        self._write_executable(self.sign_script, STUB_SIGN_SCRIPT)
        self._write_executable(self.codesign_bin, STUB_CODESIGN_BIN)
        self._write_executable(self.security_bin, STUB_SECURITY_BIN)
        self._write_executable(self.notary_bin, STUB_MACOS_NOTARY)
        self._write_executable(self.lsregister_bin, STUB_LSREGISTER)
        self._write_executable(self.bin_dir / "notarytool", TRAP_NOTARYTOOL)
        self._write_executable(self.bin_dir / "xcrun", TRAP_XCRUN)
        self._write_executable(self.profile_bin_dir / "macos-notary-profile", STUB_MACOS_NOTARY_PROFILE)

    def tearDown(self) -> None:
        if REAL_LSREGISTER.is_file() and self.sandbox.exists():
            for app in sorted(self.sandbox.rglob("*.app"), key=lambda p: len(p.parts), reverse=True):
                if not app.is_symlink():
                    subprocess.run([str(REAL_LSREGISTER), "-u", str(app)], capture_output=True, check=False)
        shutil.rmtree(self.sandbox, ignore_errors=True)

    def _write_executable(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _read_spy(self) -> list[list[str]]:
        if not self.spy_log.exists():
            return []
        return [json.loads(line) for line in self.spy_log.read_text(encoding="utf-8").splitlines()]

    def _run_release(
        self,
        *args: str,
        extra_env: dict[str, str] | None = None,
        with_profile_cmd: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        path_parts = [str(self.bin_dir)]
        if with_profile_cmd:
            path_parts.insert(0, str(self.profile_bin_dir))
        py_dir = str(Path(sys.executable).resolve().parent)
        if py_dir not in path_parts:
            path_parts.append(py_dir)
        path_parts.extend(["/usr/bin", "/bin"])

        env = dict(os.environ)
        for key in ("KOE_NOTARY_PROFILE", "NOTARY_PROFILE", "MACOS_NOTARY_PROFILE"):
            env.pop(key, None)
        env.update(
            {
                "PATH": os.pathsep.join(path_parts),
                "KOE_RELEASE_TEMP_DIR": str(self.temp_dir),
                "KOE_RELEASE_SKIP_BUILD": "1",
                "KOE_INSTALL_SCRIPT": str(self.install_script),
                "KOE_SIGN_SCRIPT": str(self.sign_script),
                "KOE_CODESIGN_BIN": str(self.codesign_bin),
                "KOE_SECURITY_BIN": str(self.security_bin),
                "MACOS_NOTARY_BIN": str(self.notary_bin),
                "KOE_LSREGISTER": str(self.lsregister_bin),
                "KOE_CLEANUP_SETTLE_SECONDS": "0",
                "KOE_SPY_LOG": str(self.spy_log),
                "KOE_TEST_ENTITLEMENTS": str(REPO_ROOT / "platforms" / "macos" / "Release.entitlements"),
            }
        )
        if extra_env:
            env.update(extra_env)

        return subprocess.run(
            [str(RELEASE_SCRIPT), *args],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def _assert_clean_temp_dir(self) -> None:
        leftovers = [p.name for p in self.temp_dir.iterdir()]
        self.assertEqual(leftovers, [], f"expected temporary staging directories removed, found {leftovers}")

    def test_release_stages_resigns_with_timestamp_submits_xw_notary_and_writes_checksums(self) -> None:
        proc = self._run_release("--dry-run", "--output-dir", str(self.output_dir))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self._assert_clean_temp_dir()

        events = self._read_spy()
        install_calls = [e for e in events if e[0] == "install-macos.sh"]
        self.assertEqual(len(install_calls), 1)
        self.assertIn("--skip-self-check", install_calls[0])
        self.assertNotIn("--keep-legacy", install_calls[0])
        self.assertIn("--skip-build", install_calls[0])
        staged_app = install_calls[0][1]

        codesign_signs = [e for e in events if e[0] == "codesign" and "--sign" in e]
        self.assertEqual(len(codesign_signs), 2, f"expected dylib + app signs, got {codesign_signs}")
        dylib_sign, app_sign = codesign_signs
        self.assertTrue(dylib_sign[-1].endswith("libmock.dylib"))
        self.assertIn("--timestamp", dylib_sign)
        self.assertIn("runtime", dylib_sign)
        self.assertNotIn("--timestamp=none", dylib_sign)

        self.assertEqual(app_sign[-1], staged_app)
        self.assertIn("--timestamp", app_sign)
        self.assertIn("runtime", app_sign)
        self.assertIn("--entitlements", app_sign)
        ent_idx = app_sign.index("--entitlements")
        self.assertEqual(
            Path(app_sign[ent_idx + 1]).resolve(),
            (REPO_ROOT / "platforms" / "macos" / "Release.entitlements").resolve(),
        )

        self.assertIn(["sign-macos.sh", "--verify-only", staged_app], events)
        self.assertIn(["koe", f"{staged_app}/Contents/MacOS/Koe", "--verify-self"], events)
        self.assertIn(["koe", f"{staged_app}/Contents/MacOS/Koe", "--smoke-test"], events)

        notary_calls = [e for e in events if e[0] == "macos-notary"]
        self.assertEqual(
            notary_calls,
            [["macos-notary", "submit", staged_app, "--profile", "xw-notary", "--dry-run"]],
        )
        self.assertFalse(any(e[0] in ("notarytool", "xcrun") for e in events))

        for call in notary_calls:
            for token in call:
                self.assertIsNone(FORBIDDEN_NOTARY_PROFILE_RE.search(token), f"invented notary name in {call}")

        sums_file = self.output_dir / "SHA256SUMS.txt"
        self.assertTrue(sums_file.is_file())
        checksum_proc = subprocess.run(
            ["shasum", "-a", "256", "-c", str(sums_file)],
            cwd=self.output_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(checksum_proc.returncode, 0, checksum_proc.stderr)
        zips = list(self.output_dir.glob("Koe-2.2.0-macos-*.zip"))
        self.assertEqual(len(zips), 1)

    def test_release_rejects_timestamp_none_flag_and_missing_tsa_timestamp(self) -> None:
        cli_proc = self._run_release("--timestamp=none", "--output-dir", str(self.output_dir))
        self.assertNotEqual(cli_proc.returncode, 0)
        self.assertIn("--timestamp=none", cli_proc.stderr)
        self.assertEqual(self._read_spy(), [])
        self._assert_clean_temp_dir()

        for env_flag in (
            "KOE_TEST_NO_TIMESTAMP",
            "KOE_TEST_EXPLICIT_TIMESTAMP_NONE",
            "KOE_TEST_ADHOC",
            "KOE_TEST_DROP_ENTITLEMENTS",
        ):
            with self.subTest(env_flag=env_flag):
                self.spy_log.unlink(missing_ok=True)
                proc = self._run_release(
                    "--output-dir",
                    str(self.output_dir),
                    extra_env={env_flag: "1"},
                )
                self.assertNotEqual(proc.returncode, 0)
                self._assert_clean_temp_dir()
                events = self._read_spy()
                self.assertFalse(any(e[0] == "macos-notary" for e in events))
                self.assertFalse((self.output_dir / "SHA256SUMS.txt").exists())

    def test_release_fails_cleanly_when_designated_requirement_changes(self) -> None:
        proc = self._run_release(
            "--output-dir",
            str(self.output_dir),
            extra_env={"KOE_TEST_MUTATE_DR": "1"},
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("designated requirement", proc.stderr.lower())
        self._assert_clean_temp_dir()
        events = self._read_spy()
        self.assertFalse(any(e[0] == "macos-notary" for e in events))
        self.assertFalse((self.output_dir / "SHA256SUMS.txt").exists())

    def test_release_profile_precedence_and_no_invented_notary_names(self) -> None:
        proc_cmd = self._run_release(
            "--dry-run",
            "--output-dir",
            str(self.output_dir / "cmd"),
            with_profile_cmd=True,
            extra_env={"KOE_TEST_PROFILE_CMD_VALUE": "team-profile"},
        )
        self.assertEqual(proc_cmd.returncode, 0, proc_cmd.stderr)
        notary_calls = [e for e in self._read_spy() if e[0] == "macos-notary"]
        self.assertEqual(notary_calls[-1][4], "team-profile")

        self.spy_log.unlink(missing_ok=True)
        proc_env = self._run_release(
            "--dry-run",
            "--output-dir",
            str(self.output_dir / "env"),
            with_profile_cmd=True,
            extra_env={
                "KOE_TEST_PROFILE_CMD_VALUE": "team-profile",
                "KOE_NOTARY_PROFILE": "override-profile",
            },
        )
        self.assertEqual(proc_env.returncode, 0, proc_env.stderr)
        notary_calls = [e for e in self._read_spy() if e[0] == "macos-notary"]
        self.assertEqual(notary_calls[-1][4], "override-profile")

    def test_release_app_mode_preserves_source_and_cleans_stage_on_notary_failure(self) -> None:
        source_app = self.sandbox / "Existing" / "Koe.app"
        (source_app / "Contents" / "MacOS").mkdir(parents=True)
        (source_app / "Contents" / "Resources").mkdir(parents=True)
        with open(source_app / "Contents" / "Info.plist", "wb") as fh:
            plistlib.dump(
                {
                    "CFBundleExecutable": "Koe",
                    "CFBundleIdentifier": "com.anker.ankerRecorder",
                    "CFBundleName": "Koe",
                    "CFBundleShortVersionString": "2.2.0",
                },
                fh,
            )
        exe = source_app / "Contents" / "MacOS" / "Koe"
        exe.write_text("#!/usr/bin/env python3\nimport sys\n", encoding="utf-8")
        exe.chmod(0o755)
        sentinel = source_app / "Contents" / "Resources" / "source.txt"
        sentinel.write_text("immutable-source\n", encoding="utf-8")

        proc = self._run_release(
            "--app",
            str(source_app),
            "--output-dir",
            str(self.output_dir),
            extra_env={"KOE_TEST_FAIL_NOTARY": "1"},
        )
        self.assertNotEqual(proc.returncode, 0)
        self._assert_clean_temp_dir()
        self.assertFalse((source_app / "Contents" / ".stub_resigned").exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "immutable-source\n")
        self.assertFalse((self.output_dir / "SHA256SUMS.txt").exists())


if __name__ == "__main__":
    unittest.main()
