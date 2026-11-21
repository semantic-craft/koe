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

fail_at = os.environ.get("KOE_FAIL_AT_PATH")
fail_flag = os.environ.get("KOE_FAIL_ON_FLAG", "--verify-self")
if fail_at and Path(fail_at).resolve() == exe and flag == fail_flag:
    sys.stderr.write(f"simulated failure at {exe} {flag}\\n")
    raise SystemExit(1)
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
        shutil.copy2(REPO_ROOT / "THIRD_PARTY_NOTICES.md", root)
        shutil.copytree(REPO_ROOT / "assets" / "licenses", root / "assets" / "licenses")
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
        cwd: Path | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        root = script_root or self.repo
        env = dict(
            os.environ,
            KOE_BUILD_APP=str(self.build_app),
            KOE_SIGN_SCRIPT=str(self.sign_script),
            KOE_LSREGISTER=str(self.lsregister_spy),
            KOE_CLEANUP_SETTLE_SECONDS="0",
            KOE_SPY_LOG=str(self.spy_log),
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(root / "scripts" / "install-macos.sh"), *args],
            cwd=cwd or root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_dump_info_plist_writes_stdout_and_rejects_write_info_plist_flag(self) -> None:
        proc = subprocess.run(
            [str(REPO_ROOT / "scripts" / "install-macos.sh"), "--dump-info-plist"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        plist = plistlib.loads(proc.stdout.encode("utf-8"))
        self.assertEqual(plist.get("CFBundleIconFile"), "AppIcon")
        self.assertNotIn("CFBundleIconName", plist)
        self.assertNotIn("CFBundleIcons", plist)
        for key in REQUIRED_USAGE_KEYS:
            self.assertTrue(isinstance(plist.get(key), str) and plist[key], f"missing {key}")

        import re
        cargo_toml = (REPO_ROOT / "Cargo.toml").read_text(encoding="utf-8")
        engine_toml = (REPO_ROOT / "crates" / "koe-engine" / "Cargo.toml").read_text(encoding="utf-8")
        engine_ver_rs = (REPO_ROOT / "crates" / "koe-engine" / "src" / "version.rs").read_text(encoding="utf-8")
        swift_snap = (
            REPO_ROOT / "platforms" / "apple-shared" / "Sources" / "KoeAppleCore" / "AppUpdateSnapshot.swift"
        ).read_text(encoding="utf-8")

        ws_ver = re.search(r'^version\s*=\s*"([^"]+)"', cargo_toml, re.M)
        eng_ver = re.search(r'^version\s*=\s*"([^"]+)"', engine_toml, re.M)
        eng_build = re.search(r'KOE_APP_BUILD:\s*&str\s*=\s*"([^"]+)"', engine_ver_rs)
        swift_ver = re.search(r'defaultVersion\s*=\s*"([^"]+)"', swift_snap)
        swift_build = re.search(r'defaultBuild\s*=\s*"([^"]+)"', swift_snap)
        self.assertIsNotNone(ws_ver)
        self.assertIsNotNone(eng_ver)
        self.assertIsNotNone(eng_build)
        self.assertIsNotNone(swift_ver)
        self.assertIsNotNone(swift_build)
        assert ws_ver and eng_ver and eng_build and swift_ver and swift_build
        self.assertEqual(plist.get("CFBundleShortVersionString"), ws_ver.group(1))
        self.assertEqual(plist.get("CFBundleShortVersionString"), eng_ver.group(1))
        self.assertEqual(plist.get("CFBundleShortVersionString"), swift_ver.group(1))
        self.assertEqual(plist.get("CFBundleVersion"), eng_build.group(1))
        self.assertEqual(plist.get("CFBundleVersion"), swift_build.group(1))

        bypass_file = self.sandbox / "should-not-exist.plist"
        legacy = subprocess.run(
            [str(REPO_ROOT / "scripts" / "install-macos.sh"), "--write-info-plist", str(bypass_file)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(legacy.returncode, 0)
        self.assertFalse(bypass_file.exists())

    def test_cross_platform_release_metadata_lockstep_and_ios_app_icon(self) -> None:
        import re

        def extract(rel_path: str, pattern: str, flags: int = 0) -> str:
            text = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
            match = re.search(pattern, text, flags)
            self.assertIsNotNone(match, f"missing pattern {pattern!r} in {rel_path}")
            assert match is not None
            return match.group(1)

        expected_version = extract("Cargo.toml", r'^version\s*=\s*"([^"]+)"', re.M)
        expected_build = extract("crates/koe-engine/src/version.rs", r'KOE_APP_BUILD:\s*&str\s*=\s*"([^"]+)"')

        self.assertEqual(extract("platforms/ios/project.yml", r'MARKETING_VERSION:\s*"([^"]+)"'), expected_version)
        self.assertEqual(extract("platforms/ios/project.yml", r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"'), expected_build)
        self.assertEqual(
            extract("platforms/android/gradle-app/app/build.gradle.kts", r'versionName\s*=\s*"([^"]+)"'),
            expected_version,
        )
        self.assertEqual(
            extract("platforms/android/gradle-app/app/build.gradle.kts", r'versionCode\s*=\s*(\d+)'),
            expected_build,
        )
        android_models = (
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/HostDeviceAndCaptureModels.kt"
        )
        self.assertEqual(extract(android_models, r'DEFAULT_VERSION\s*=\s*"([^"]+)"'), expected_version)
        self.assertEqual(extract(android_models, r'DEFAULT_BUILD\s*=\s*"([^"]+)"'), expected_build)
        extract("platforms/ios/project.yml", r'(ASSETCATALOG_COMPILER_APPICON_NAME:\s*AppIcon\b)')

        ios_assets = REPO_ROOT / "platforms" / "ios" / "App" / "Assets.xcassets"
        ios_app_icon = ios_assets / "AppIcon.appiconset" / "AppIcon.png"
        self.assertTrue((ios_assets / "Contents.json").is_file(), "missing Assets.xcassets/Contents.json")
        self.assertTrue(
            (ios_assets / "AppIcon.appiconset" / "Contents.json").is_file(),
            "missing AppIcon.appiconset/Contents.json",
        )
        self.assertTrue(ios_app_icon.is_file(), f"missing iOS AppIcon asset: {ios_app_icon}")
        self.assertGreater(ios_app_icon.stat().st_size, 0, "iOS AppIcon.png must be non-empty")

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

    def test_skip_build_installs_current_third_party_notices(self) -> None:
        bundle_path = Path("Contents/Resources/Licenses")
        notice = Path("THIRD_PARTY_NOTICES.md")
        license_path = Path("assets/licenses")
        old_licenses = self.build_app / bundle_path
        (old_licenses / license_path).mkdir(parents=True)
        (old_licenses / notice).write_bytes(b"stale notice\n")
        (old_licenses / license_path / "retired.txt").write_bytes(b"stale license\n")
        install_app = self.sandbox / "Install" / "Koe.app"

        proc = self._run_installer(
            "--skip-build",
            extra_env={"MACOS_INSTALL_PATH": str(install_app)},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

        installed = install_app / bundle_path
        self.assertEqual((installed / notice).read_bytes(), (self.repo / notice).read_bytes())
        expected_paths = {
            source.relative_to(self.repo)
            for source in (self.repo / license_path).rglob("*")
            if source.is_file()
        }
        installed_paths = {
            path.relative_to(installed)
            for path in (installed / license_path).rglob("*")
            if path.is_file()
        }
        self.assertEqual(installed_paths, expected_paths)
        for path in sorted(expected_paths):
            with self.subTest(license=path):
                self.assertEqual((installed / path).read_bytes(), (self.repo / path).read_bytes())

    def test_skip_build_rejects_symlinked_license_parents_without_modifying_external_files(self) -> None:
        licenses = Path("Contents/Resources/Licenses")
        for linked_parent in (Path("Contents"), licenses.parent):
            with self.subTest(linked_parent=linked_parent):
                case = self.sandbox / linked_parent.name
                source = self._make_build_app(case / "Build" / "Koe.app")
                install_app = case / "Install" / "Koe.app"
                external = case / "External"
                (source / linked_parent).rename(external)
                (source / linked_parent).symlink_to(external)
                external_licenses = external / licenses.relative_to(linked_parent)
                external_licenses.mkdir()
                sentinel = external_licenses / "keep.txt"
                sentinel.write_bytes(b"external license\n")

                proc = self._run_installer(
                    "--skip-build",
                    extra_env={"KOE_BUILD_APP": str(source), "MACOS_INSTALL_PATH": str(install_app)},
                )

                self.assertEqual(list(external_licenses.iterdir()), [sentinel])
                self.assertEqual(sentinel.read_bytes(), b"external license\n")
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertFalse(install_app.exists())

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

    def test_path_guard_blocks_symlink_dotdot_system_tree_and_unicode_normalization_overlap(self) -> None:
        inside_bypass = self.repo / "InsideRepoBypass.app"
        inside_bypass.mkdir(parents=True, exist_ok=True)
        (inside_bypass / "sentinel.txt").write_text("inside-repo-bypass\n", encoding="utf-8")
        sym_repo = self.sandbox / "sym_repo"
        sym_repo.symlink_to(self.repo / "scripts")
        proc = self._run_installer(
            "--skip-build",
            extra_env={"MACOS_INSTALL_PATH": f"{sym_repo}/../InsideRepoBypass.app"},
        )
        self.assertNotEqual(proc.returncode, 0, "symlink/.. into repo must be rejected")
        self.assertTrue((inside_bypass / "sentinel.txt").is_file())

        sym_apps = self.sandbox / "sym_apps"
        sym_apps.symlink_to("/Applications/Utilities")
        proc_safari = self._run_installer(
            "--validate-paths-only",
            extra_env={"MACOS_INSTALL_PATH": f"{sym_apps}/../Safari.app"},
        )
        self.assertNotEqual(proc_safari.returncode, 0, "symlink/.. into /Applications must be rejected")

        proc_sys = self._run_installer(
            "--validate-paths-only",
            extra_env={"MACOS_INSTALL_PATH": "/System/Applications/Mail.app"},
        )
        self.assertNotEqual(proc_sys.returncode, 0, "/System/Applications/Mail.app must be rejected")

        proc_nfd = self._run_installer(
            "--validate-paths-only",
            extra_env={
                "KOE_BUILD_APP": str(self.sandbox / "Caf\u00e9" / "Koe.app"),
                "MACOS_INSTALL_PATH": str(self.sandbox / "Cafe\u0301" / "Koe.app"),
            },
        )
        self.assertNotEqual(proc_nfd.returncode, 0, "NFC vs NFD normalization overlap must be rejected")

        caller_cwd = self.sandbox / "CallerWorkingDir"
        caller_cwd.mkdir(parents=True, exist_ok=True)
        real_app = self.sandbox / "CallerReal.app"
        real_app.mkdir(parents=True, exist_ok=True)
        (caller_cwd / "RelativeLink.app").symlink_to(real_app)
        proc_rel = self._run_installer(
            "--validate-paths-only",
            cwd=caller_cwd,
            extra_env={"MACOS_INSTALL_PATH": "RelativeLink.app"},
        )
        self.assertNotEqual(proc_rel.returncode, 0, "relative symlink from caller cwd must be rejected")

    def test_post_swap_failure_rolls_back_atomically_sweeps_orphan_stage_and_checks_lsregister(self) -> None:
        install_app = self.sandbox / "RollbackInstall" / "Koe.app"
        self._make_build_app(install_app)
        obsolete = install_app / "Contents" / "Resources" / "obsolete.txt"
        obsolete.write_text("keep-existing-bundle\n", encoding="utf-8")
        subprocess.run(["codesign", "--force", "--sign", "-", str(install_app)], check=True)

        missing_lsreg = self._run_installer(
            "--skip-build",
            extra_env={
                "MACOS_INSTALL_PATH": str(install_app),
                "KOE_LSREGISTER": str(self.sandbox / "nonexistent-lsregister"),
            },
        )
        self.assertNotEqual(missing_lsreg.returncode, 0, "missing KOE_LSREGISTER must fail fast")
        self.assertTrue(obsolete.is_file())

        orphan_stage = install_app.parent / ".Koe.stage.CRASHED"
        orphan_app = orphan_stage / "Koe.app"
        orphan_app.mkdir(parents=True, exist_ok=True)

        proc = self._run_installer(
            "--skip-build",
            extra_env={
                "MACOS_INSTALL_PATH": str(install_app),
                "KOE_FAIL_AT_PATH": str(install_app / "Contents" / "MacOS" / "Koe"),
                "KOE_FAIL_ON_FLAG": "--verify-self",
            },
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(obsolete.is_file(), "post-swap failure must roll back previous bundle")
        self.assertEqual(obsolete.read_text(encoding="utf-8"), "keep-existing-bundle\n")
        leftover_stages = [
            p.name for p in install_app.parent.iterdir() if p.name.startswith(".Koe.stage.")
        ]
        self.assertEqual(leftover_stages, [])

        events = self._read_spy_events()
        self.assertIn(["lsregister", "-u", str(orphan_app)], events)
        fail_event = ["koe", str(install_app / "Contents" / "MacOS" / "Koe"), "--verify-self"]
        self.assertIn(fail_event, events)
        fail_idx = events.index(fail_event)
        self.assertIn(["lsregister", "-f", str(install_app)], events[fail_idx + 1 :])

    def test_live_process_inside_target_blocks_overwrite_across_metacharacters_and_case_folding(self) -> None:
        sleeper_src = self.sandbox / "sleeper.c"
        sleeper_src.write_text(
            '#include <unistd.h>\nint main(void) { write(1, "R", 1); pause(); return 0; }\n',
            encoding="utf-8",
        )
        install_dir = self.sandbox / "LiveInstall"
        install_app = install_dir / "Koe [Beta].app"
        self._make_build_app(install_app)
        obsolete = install_app / "Contents" / "Resources" / "obsolete.txt"
        obsolete.write_text("live-bundle\n", encoding="utf-8")
        exe = install_app / "Contents" / "MacOS" / "Koe"
        subprocess.run(["cc", str(sleeper_src), "-o", str(exe)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(install_app)], check=True)

        live_proc = subprocess.Popen([str(exe)], stdout=subprocess.PIPE)
        try:
            assert live_proc.stdout is not None
            self.assertEqual(live_proc.stdout.read(1), b"R")

            proc = self._run_installer(
                "--skip-build",
                extra_env={"MACOS_INSTALL_PATH": str(install_app)},
            )
            self.assertNotEqual(proc.returncode, 0, "live process with regex metacharacters must block install")
            self.assertIn("Quit Koe before installing.", proc.stderr)
            self.assertTrue(obsolete.is_file())

            folded_path = self.sandbox / "liveinstall" / "koe [beta].app"
            if folded_path.exists() and folded_path.samefile(install_app):
                proc_folded = self._run_installer(
                    "--skip-build",
                    extra_env={"MACOS_INSTALL_PATH": str(folded_path)},
                )
                self.assertNotEqual(proc_folded.returncode, 0, "case-folded live bundle path must block install")
                self.assertIn("Quit Koe before installing.", proc_folded.stderr)
                self.assertTrue(obsolete.is_file())
                entries = [p.name for p in install_dir.iterdir()]
                self.assertIn("Koe [Beta].app", entries)
        finally:
            if live_proc.stdout is not None:
                live_proc.stdout.close()
            live_proc.terminate()
            live_proc.wait()


if __name__ == "__main__":
    unittest.main()
