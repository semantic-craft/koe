#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent
REAL_LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
)
CACHE_ROOT = Path(
    subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip()
).resolve()

REQUIRED_USAGE_KEYS = (
    "NSBluetoothAlwaysUsageDescription",
    "NSBluetoothPeripheralUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSAudioCaptureUsageDescription",
    "NSSpeechRecognitionUsageDescription",
    "NSLocalNetworkUsageDescription",
    "NSCalendarsUsageDescription",
    "NSCalendarsFullAccessUsageDescription",
    "NSRemindersUsageDescription",
    "NSRemindersFullAccessUsageDescription",
)

STUB_SIGN_SCRIPT = """#!/usr/bin/env python3
from pathlib import Path
import os
import subprocess
import sys

args = sys.argv[1:]
verify_only = False
app = None
i = 0
while i < len(args):
    if args[i] == "--verify-only":
        verify_only = True
    elif args[i] == "--identity":
        i += 1
    else:
        app = Path(args[i])
    i += 1

if app is None or not app.is_dir():
    sys.stderr.write(f"invalid app bundle: {app}\\n")
    raise SystemExit(1)

if verify_only:
    if os.environ.get("KOE_STUB_FAIL_VERIFY") == "1":
        sys.stderr.write("simulated staged verification failure\\n")
        raise SystemExit(1)
    res = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        sys.stderr.write(res.stderr or "bundle seal verification failed\\n")
        raise SystemExit(res.returncode)
    raise SystemExit(0)

res = subprocess.run(
    ["codesign", "--force", "--sign", "-", str(app)],
    capture_output=True,
    text=True,
    check=False,
)
if res.returncode != 0:
    sys.stderr.write(res.stderr or "ad-hoc stub sign failed\\n")
    raise SystemExit(res.returncode)
"""

STUB_LSREGISTER_SCRIPT = """#!/usr/bin/env python3
import json
import os
import sys

log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["lsregister", *sys.argv[1:]]) + "\\n")
"""

STUB_KOE_BINARY = """#!/usr/bin/env python3
import json
from pathlib import Path
import os
import sys

exe = Path(sys.argv[0]).resolve()
contents = exe.parent.parent
if not (contents / "Info.plist").is_file():
    sys.stderr.write(f"missing Info.plist next to {exe}\\n")
    raise SystemExit(1)
if not (contents / "Resources" / "AppIcon.icns").is_file():
    sys.stderr.write(f"missing AppIcon.icns next to {exe}\\n")
    raise SystemExit(1)
if (contents / "Resources" / "AppIcon.png").exists():
    sys.stderr.write("unexpected unpadded AppIcon.png in Contents/Resources\\n")
    raise SystemExit(1)

flag = sys.argv[1] if len(sys.argv) > 1 else ""
if flag not in ("--verify-self", "--smoke-test"):
    sys.stderr.write(f"unexpected flag: {flag}\\n")
    raise SystemExit(2)

log_path = os.environ.get("KOE_SPY_LOG")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(["koe", str(exe), flag]) + "\\n")
"""


class InstallMacosScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        if str(CACHE_ROOT).startswith(("/tmp", "/private/tmp", "/Applications")):
            self.fail(f"Unsafe DARWIN_USER_CACHE_DIR: {CACHE_ROOT}")
        self.sandbox = Path(tempfile.mkdtemp(prefix="koe-install-test-", dir=CACHE_ROOT)).resolve()
        (self.sandbox / ".metadata_never_index").write_bytes(b"")
        self.spy_log = self.sandbox / "spy.jsonl"
        self.sign_script = self.sandbox / "bin" / "sign-macos.sh"
        self.lsregister_spy = self.sandbox / "bin" / "lsregister"
        self._write_executable(self.sign_script, STUB_SIGN_SCRIPT)
        self._write_executable(self.lsregister_spy, STUB_LSREGISTER_SCRIPT)
        self.repo = self._make_repo_mirror(self.sandbox / "repo")
        self.build_app = self._make_build_app(self.sandbox / "Build" / "Koe.app")

    def tearDown(self) -> None:
        if REAL_LSREGISTER.is_file() and self.sandbox.exists():
            for app in sorted(self.sandbox.rglob("*.app"), key=lambda p: len(p.parts), reverse=True):
                if not app.is_symlink():
                    subprocess.run(
                        [str(REAL_LSREGISTER), "-u", str(app)],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
        shutil.rmtree(self.sandbox, ignore_errors=True)

    def _write_executable(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _make_repo_mirror(self, root: Path) -> Path:
        scripts_dir = root / "scripts"
        scripts_dir.mkdir(parents=True, exist_ok=True)
        for name in ("install-macos.sh", "cleanup_app_registrations.py"):
            src = REPO_ROOT / "scripts" / name
            dst = scripts_dir / name
            shutil.copy2(src, dst)
            dst.chmod(0o755)
        self._write_executable(scripts_dir / "sign-macos.sh", STUB_SIGN_SCRIPT)
        return root

    def _make_build_app(self, app_path: Path) -> Path:
        (app_path / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
        (app_path / "Contents" / "Resources").mkdir(parents=True, exist_ok=True)
        (app_path / "Contents" / "PkgInfo").write_text("APPL????", encoding="utf-8")
        plist = {
            "CFBundleExecutable": "Koe",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": "com.anker.ankerRecorder",
            "CFBundleName": "Koe",
            "CFBundlePackageType": "APPL",
        }
        with open(app_path / "Contents" / "Info.plist", "wb") as fh:
            plistlib.dump(plist, fh)
        (app_path / "Contents" / "Resources" / "AppIcon.icns").write_bytes(b"icns-payload")
        self._write_executable(app_path / "Contents" / "MacOS" / "Koe", STUB_KOE_BINARY)
        return app_path

    def _read_spy_events(self) -> list[list[str]]:
        if not self.spy_log.exists():
            return []
        return [json.loads(line) for line in self.spy_log.read_text(encoding="utf-8").splitlines()]

    def _run_installer(
        self,
        *args: str,
        script_root: Path | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        root = script_root or self.repo
        env = dict(
            os.environ,
            KOE_BUILD_APP=str(self.build_app),
            KOE_SIGN_SCRIPT=str(self.sign_script),
            KOE_LSREGISTER=str(self.lsregister_spy),
            KOE_SPY_LOG=str(self.spy_log),
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(root / "scripts" / "install-macos.sh"), *args],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_write_info_plist_omits_assetless_icon_name_and_preserves_permissions(self) -> None:
        out_plist = self.sandbox / "Info.plist"
        proc = subprocess.run(
            [str(REPO_ROOT / "scripts" / "install-macos.sh"), "--write-info-plist", str(out_plist)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(out_plist.is_file())
        plist = plistlib.loads(out_plist.read_bytes())
        self.assertEqual(plist.get("CFBundleIconFile"), "AppIcon")
        self.assertNotIn("CFBundleIconName", plist)
        self.assertNotIn("CFBundleIcons", plist)
        for key in REQUIRED_USAGE_KEYS:
            self.assertTrue(isinstance(plist.get(key), str) and plist[key], f"missing {key}")

    def test_skip_build_replaces_bundle_atomically_and_registers_launchservices(self) -> None:
        install_app = self.sandbox / "Install" / "Koe.app"
        obsolete = install_app / "Contents" / "Resources" / "obsolete.txt"
        obsolete.parent.mkdir(parents=True, exist_ok=True)
        obsolete.write_text("stale-resource\n", encoding="utf-8")

        proc = self._run_installer(
            "--skip-build",
            extra_env={"MACOS_INSTALL_PATH": str(install_app)},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(obsolete.exists(), "whole-bundle replacement must remove obsolete files")
        self.assertTrue((install_app / "Contents" / "Info.plist").is_file())
        self.assertTrue((install_app / "Contents" / "Resources" / "AppIcon.icns").is_file())
        leftover_stages = [
            p.name for p in install_app.parent.iterdir() if p.name.startswith(".Koe.stage.")
        ]
        self.assertEqual(leftover_stages, [])

        events = self._read_spy_events()
        self.assertIn(["lsregister", "-u", str(self.build_app)], events)
        self.assertIn(["lsregister", "-f", str(install_app)], events)
        reg_idx = events.index(["lsregister", "-f", str(install_app)])
        verify_idx = events.index(["koe", str(install_app / "Contents" / "MacOS" / "Koe"), "--verify-self"])
        smoke_idx = events.index(["koe", str(install_app / "Contents" / "MacOS" / "Koe"), "--smoke-test"])
        self.assertLess(reg_idx, verify_idx)
        self.assertLess(verify_idx, smoke_idx)

    def test_staged_verification_failure_preserves_existing_target_and_cleans_stage(self) -> None:
        self._make_build_app(self.repo / "build" / "macos" / "Build" / "Products" / "Release" / "Koe.app")
        install_app = self.sandbox / "Install" / "Koe.app"
        self._make_build_app(install_app)
        obsolete = install_app / "Contents" / "Resources" / "obsolete.txt"
        obsolete.write_text("keep-existing-bundle\n", encoding="utf-8")
        subprocess.run(["codesign", "--force", "--sign", "-", str(install_app)], check=True)

        proc = self._run_installer(
            "--skip-build",
            extra_env={
                "MACOS_INSTALL_PATH": str(install_app),
                "KOE_STUB_FAIL_VERIFY": "1",
            },
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(obsolete.is_file(), "pre-existing bundle must survive failed staged verification")
        self.assertEqual(obsolete.read_text(encoding="utf-8"), "keep-existing-bundle\n")
        leftover_stages = [
            p.name for p in install_app.parent.iterdir() if p.name.startswith(".Koe.stage.")
        ]
        self.assertEqual(leftover_stages, [])
        self.assertNotIn(["lsregister", "-f", str(install_app)], self._read_spy_events())

    def test_path_guard_enforces_five_relations_and_accepts_standard_install_locations(self) -> None:
        self._make_build_app(self.repo / "build" / "macos" / "Build" / "Products" / "Release" / "Koe.app")
        fake_home = self.sandbox / "FakeHome"
        fake_home_apps = fake_home / "Applications"
        fake_home_apps.mkdir(parents=True, exist_ok=True)
        (fake_home_apps / "keep.txt").write_text("apps-root\n", encoding="utf-8")

        proc = self._run_installer(
            "--skip-build",
            extra_env={"HOME": str(fake_home), "MACOS_INSTALL_PATH": str(fake_home_apps)},
        )
        self.assertNotEqual(proc.returncode, 0, "non-.app directory must be rejected")
        self.assertTrue((fake_home_apps / "keep.txt").is_file(), "non-.app directory must stay intact")

        repo_as_app = self._make_repo_mirror(self.sandbox / "Checkout.app")
        self._make_build_app(repo_as_app / "build" / "macos" / "Build" / "Products" / "Release" / "Koe.app")
        (repo_as_app / "sentinel.txt").write_text("root-equal\n", encoding="utf-8")
        proc = self._run_installer(
            "--skip-build",
            script_root=repo_as_app,
            extra_env={"MACOS_INSTALL_PATH": str(repo_as_app)},
        )
        self.assertNotEqual(proc.returncode, 0, "target equal to $ROOT must be rejected")
        self.assertTrue((repo_as_app / "sentinel.txt").is_file())

        nested_in_root = self.repo / "InsideRepo.app"
        nested_in_root.mkdir(parents=True, exist_ok=True)
        (nested_in_root / "sentinel.txt").write_text("inside-root\n", encoding="utf-8")
        proc = self._run_installer(
            "--skip-build",
            extra_env={"MACOS_INSTALL_PATH": str(nested_in_root)},
        )
        self.assertNotEqual(proc.returncode, 0, "target inside $ROOT must be rejected")
        self.assertTrue((nested_in_root / "sentinel.txt").is_file())

        outer_app = self.sandbox / "OuterCheckout.app"
        inner_repo = self._make_repo_mirror(outer_app / "repo")
        self._make_build_app(inner_repo / "build" / "macos" / "Build" / "Products" / "Release" / "Koe.app")
        (outer_app / "sentinel.txt").write_text("contains-root\n", encoding="utf-8")
        proc = self._run_installer(
            "--skip-build",
            script_root=inner_repo,
            extra_env={"MACOS_INSTALL_PATH": str(outer_app)},
        )
        self.assertNotEqual(proc.returncode, 0, "target containing $ROOT must be rejected")
        self.assertTrue((outer_app / "sentinel.txt").is_file())

        (self.build_app / "Contents" / "Resources" / "build_sentinel.txt").write_text("build\n", encoding="utf-8")
        proc = self._run_installer(
            "--skip-build",
            extra_env={"MACOS_INSTALL_PATH": str(self.build_app)},
        )
        self.assertNotEqual(proc.returncode, 0, "target equal to KOE_BUILD_APP must be rejected")
        self.assertTrue((self.build_app / "Contents" / "Resources" / "build_sentinel.txt").is_file())

        nested_in_build = self.build_app / "Contents" / "Helpers" / "Nested.app"
        nested_in_build.mkdir(parents=True, exist_ok=True)
        (nested_in_build / "sentinel.txt").write_text("inside-build\n", encoding="utf-8")
        proc = self._run_installer(
            "--skip-build",
            extra_env={"MACOS_INSTALL_PATH": str(nested_in_build)},
        )
        self.assertNotEqual(proc.returncode, 0, "target inside KOE_BUILD_APP must be rejected")
        self.assertTrue((nested_in_build / "sentinel.txt").is_file())

        umbrella_build = self.sandbox / "UmbrellaBuild.app"
        contained_source = self._make_build_app(umbrella_build / "Sub" / "Koe.app")
        (umbrella_build / "sentinel.txt").write_text("contains-build\n", encoding="utf-8")
        proc = self._run_installer(
            "--skip-build",
            extra_env={
                "KOE_BUILD_APP": str(contained_source),
                "MACOS_INSTALL_PATH": str(umbrella_build),
            },
        )
        self.assertNotEqual(proc.returncode, 0, "target containing KOE_BUILD_APP must be rejected")
        self.assertTrue((umbrella_build / "sentinel.txt").is_file())

        real_bundle = self.sandbox / "RealTarget.app"
        real_bundle.mkdir(parents=True, exist_ok=True)
        (real_bundle / "sentinel.txt").write_text("real-target\n", encoding="utf-8")
        symlink_target = self.sandbox / "LinkTarget.app"
        symlink_target.symlink_to(real_bundle)
        proc = self._run_installer(
            "--skip-build",
            extra_env={"MACOS_INSTALL_PATH": str(symlink_target)},
        )
        self.assertNotEqual(proc.returncode, 0, "symlink at MACOS_INSTALL_PATH must be rejected")
        self.assertTrue(symlink_target.is_symlink(), "symlink at MACOS_INSTALL_PATH must remain untouched")
        self.assertTrue((real_bundle / "sentinel.txt").is_file())

        mixed_source = self._make_build_app(self.sandbox / "MixedBuild" / "Koe.app")
        (mixed_source / "Contents" / "Resources" / "case_sentinel.txt").write_text("case\n", encoding="utf-8")
        folded_alias = self.sandbox / "mixedbuild" / "koe.app"
        if folded_alias.exists() and mixed_source.samefile(folded_alias):
            proc = self._run_installer(
                "--skip-build",
                extra_env={
                    "KOE_BUILD_APP": str(mixed_source),
                    "MACOS_INSTALL_PATH": str(folded_alias),
                },
            )
            self.assertNotEqual(proc.returncode, 0, "case-folded alias on APFS must be rejected")
            self.assertTrue((mixed_source / "Contents" / "Resources" / "case_sentinel.txt").is_file())

        for rejected in ("/", "/Applications", str(Path.home()), str(Path.home() / "Applications")):
            proc = subprocess.run(
                [str(REPO_ROOT / "scripts" / "install-macos.sh"), "--validate-paths-only"],
                cwd=REPO_ROOT,
                env=dict(
                    os.environ,
                    KOE_BUILD_APP=str(self.build_app),
                    MACOS_INSTALL_PATH=rejected,
                ),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc.returncode, 0, f"expected {rejected} to be rejected")

        for accepted in (
            "/Applications/Koe.app",
            "~/Applications/Koe.app",
            str(Path.home() / "Applications" / "Koe.app"),
        ):
            proc = subprocess.run(
                [str(REPO_ROOT / "scripts" / "install-macos.sh"), "--validate-paths-only"],
                cwd=REPO_ROOT,
                env=dict(
                    os.environ,
                    KOE_BUILD_APP=str(self.build_app),
                    MACOS_INSTALL_PATH=accepted,
                ),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"expected {accepted} to pass guard: {proc.stderr}")


if __name__ == "__main__":
    unittest.main()
