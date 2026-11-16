#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


def load_verifier():
    script_path = Path(__file__).resolve().parent / "verify-ui-principles.py"
    spec = importlib.util.spec_from_file_location("verify_ui_principles", script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verifier = load_verifier()


LEGACY_LIGHT_THEME = """
pub struct AppFontSizes;
impl AppFontSizes {
    pub const XS: f32 = 12.0;
    pub const SM: f32 = 14.0;
    pub const MD: f32 = 16.0;
    pub const LG: f32 = 22.0;
}
pub struct AppRadii;
impl AppRadii {
    pub const fn concentric(outer: f32, padding: f32) -> f32 { outer - padding }
}
pub struct AppColors;
impl AppColors {
    pub const SURFACE_0: u32 = 0xFFFFFFFF;
    pub const BG_PANEL: u32 = 0xFFF7F7F8;
    pub const SURFACE_1: u32 = 0xFFFFFFFF;
    pub const BG_CARD: u32 = 0xFFFFFFFF;
    pub const BG_SUBTLE: u32 = 0xFFF1F1F3;
    pub const BG_CARD_HOVER: u32 = 0xFFECECEF;
    pub const BG_MUTED: u32 = 0xFFF1F1F3;
    pub const BORDER: u32 = 0xFFE3E3E7;
    pub const BORDER_SOFT: u32 = 0xFFEBEBEE;
    pub const TEXT_PRIMARY: u32 = 0xFF202022;
    pub const TEXT_SECONDARY: u32 = 0xFF54545B;
    pub const TEXT_MUTED: u32 = 0xFF686870;
    pub const ACCENT: u32 = 0xFF242426;
    pub const ON_ACCENT: u32 = 0xFFFFFFFF;
    pub const CARD_SHADOW: &[u32] = &[];
}
"""


VALID_LIGHT_THEME = (
    Path(__file__).resolve().parent.parent
    / "platforms/apple-shared/Sources/KoeAppleShared/DesignKit.swift"
).read_text(encoding="utf-8")


class VerifyUiPrinciplesTest(unittest.TestCase):
    def test_accepts_approved_light_palette(self) -> None:
        res = verifier.check_theme_file(VALID_LIGHT_THEME)
        self.assertEqual(res["violations"], [])
        self.assertGreaterEqual(res["accent"]["foreground_contrast"], 4.5)

    def test_rejects_colored_accents(self) -> None:
        for color in ("0xD9480F", "0x0066CC", "0xC4B5FD"):
            res = verifier.check_theme_file(VALID_LIGHT_THEME.replace("0x242426", color))
            self.assertTrue(any("approved charcoal" in v for v in res["violations"]), res["violations"])

    def test_rejects_unreadable_text_and_action_foreground(self) -> None:
        for before, after in (("textMuted = Color(hex: 0x686870)", "textMuted = Color(hex: 0xBBBBBB)"),
                              ("onAccent = Color(hex: 0xFFFFFF)", "onAccent = Color(hex: 0x202022)")):
            res = verifier.check_theme_file(VALID_LIGHT_THEME.replace(before, after))
            self.assertTrue(any("contrast" in v for v in res["violations"]), res["violations"])

    def test_rejects_dark_surface(self) -> None:
        res = verifier.check_theme_file(VALID_LIGHT_THEME.replace("surface0 = Color(hex: 0xFFFFFF)", "surface0 = Color(hex: 0x1A1A1D)"))
        self.assertTrue(any("light surface" in v for v in res["violations"]), res["violations"])

    def test_catches_font_size_sprawl_middle_dots_uppercase_and_italics_in_swiftui(self) -> None:
        bad_swift_ui = """
        import SwiftUI
        struct SampleView: View {
            var body: some View {
                VStack {
                    Text("录音中 · 打开".uppercased()).font(.system(size: 11)).italic()
                    Text("二").font(.system(size: 12))
                    Text("三").font(.system(size: 13))
                    Text("四").font(.system(size: 15))
                    Text("立即开启").font(.system(size: 20))
                }
            }
        }
        """
        res = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/SampleView.swift",
            bad_swift_ui,
            strict_scale=True,
        )
        joined = "\n".join(res["violations"])
        self.assertIn("distinct font sizes", joined)
        self.assertIn("off-scale font sizes", joined)
        self.assertIn("middle dot", joined)
        self.assertIn(".italic()", joined)
        self.assertIn(".uppercased()", joined)
        self.assertIn("pushy marketing verb", joined)

    def test_accepts_clean_swiftui_file_within_4_size_scale(self) -> None:
        clean_swift_ui = """
        import SwiftUI
        struct CleanView: View {
            var body: some View {
                VStack {
                    Text("随心记录").font(.system(size: 22))
                    Text("连接录音豆").font(.system(size: 16))
                    Text("正文段落").font(.system(size: 14))
                    Text("12:30").font(.system(size: 12))
                }
            }
        }
        """
        res = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/CleanView.swift",
            clean_swift_ui,
            strict_scale=True,
        )
        self.assertEqual(res["violations"], [])

    def test_parses_app_font_sizes_tokens_and_rejects_unknown_token(self) -> None:
        token_ui = """
        import SwiftUI
        struct TokenView: View {
            var body: some View {
                VStack {
                    Text("标题").font(.system(size: AppFontSizes.lg))
                    Text("小节").font(.system(size: AppFontSizes.md))
                    Text("正文").font(.system(size: AppFontSizes.sm))
                    Text("说明").font(.system(size: AppFontSizes.xs))
                }
            }
        }
        """
        res = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/TokenView.swift",
            token_ui,
            strict_scale=True,
        )
        self.assertEqual(res["violations"], [])
        self.assertEqual(res["distinct_font_sizes"], [12.0, 14.0, 16.0, 22.0])

        bad_token_ui = token_ui.replace("AppFontSizes.lg", "AppFontSizes.xxl")
        res_bad = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/TokenView.swift",
            bad_token_ui,
            strict_scale=True,
        )
        self.assertTrue(
            any("unknown AppFontSizes token" in v for v in res_bad["violations"]),
            res_bad["violations"],
        )

    def test_rejects_dynamic_font_size_reversible_trash_dialog_and_oversized_files(self) -> None:
        adversarial_ui = """
        import SwiftUI
        struct AdversarialView: View {
            let color = 0xFFB66C50
            var body: some View {
                VStack {
                    Text("85%").font(.system(size: width * 0.21))
                    Text("移到回收站？")
                    Text("立即同步")
                }
            }
        }
        """
        res = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/AdversarialView.swift",
            adversarial_ui,
            strict_scale=True,
        )
        joined = "\n".join(res["violations"])
        self.assertIn("dynamic off-scale fontSize expression", joined)
        self.assertIn("移到回收站？", joined)
        self.assertIn("legacy terracotta color", joined)
        self.assertIn("pushy marketing verb", joined)

        oversized = "\n".join(["// line"] * 505)
        res_oversized = verifier.check_ui_file(
            "crates/koe-host-api/src/lib.rs",
            oversized,
            strict_scale=True,
        )
        self.assertTrue(
            any("max is 500 lines" in v for v in res_oversized["violations"]),
            res_oversized["violations"],
        )

    def test_rejects_plain_button_dead_zones_unsubmitted_textfields_and_ux_regressions(self) -> None:
        bad_plain_order = """
        import SwiftUI
        struct DeadZoneView: View {
            @State private var text = ""
            var body: some View {
                VStack {
                    Button {
                    } label: {
                        HStack {
                            Text("点我").font(.system(size: AppFontSizes.sm))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    TextField("输入...", text: $text)
                }
            }
        }
        """
        res = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/AskView.swift",
            bad_plain_order,
            strict_scale=True,
        )
        joined = "\n".join(res["violations"])
        self.assertIn("wrap .contentShape(Rectangle()) inside the label closure", joined)
        self.assertIn("TextField(s) but only 0 .onSubmit", joined)
        self.assertIn("must render ask.messages", joined)

        bad_mac_app = """
        import AppKit
        enum KoeWindowPresenter {
            static func open() {
                let w = NSApp?.windows.first(where: { $0.canBecomeMain }) ?? NSApp?.windows.first
                _ = w
            }
        }
        """
        res_mac = verifier.check_ui_file(
            "platforms/macos/Sources/Koe/KoeMacApp.swift",
            bad_mac_app,
            strict_scale=True,
        )
        self.assertTrue(
            any("isWorkspaceWindow" in v for v in res_mac["violations"]),
            res_mac["violations"],
        )

        bad_player = """
        import SwiftUI
        struct PlayerBarView: View {
            var body: some View {
                Text("mark").onTapGesture {
                    let _ = durationMs + 1000
                }
            }
        }
        """
        res_player = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/PlayerBarView.swift",
            bad_player,
            strict_scale=True,
        )
        self.assertTrue(
            any("durationMs + 1000" in v for v in res_player["violations"]),
            res_player["violations"],
        )

        bad_install = "#!/usr/bin/env bash\necho 'missing plist keys'\n"
        install_violations = verifier.check_install_script(bad_install)
        self.assertTrue(
            any("NSLocalNetworkUsageDescription" in v for v in install_violations),
            install_violations,
        )

    def test_install_script_icon_and_lsregister_contracts(self) -> None:
        valid_lines = [
            "#!/usr/bin/env bash",
            'LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"',
            *verifier.REQUIRED_INSTALL_PLIST_KEYS,
            '"$LSREGISTER" -f "$TARGET"',
        ]
        valid_script = "\n".join(valid_lines) + "\n"
        self.assertEqual(verifier.check_install_script(valid_script), [])

        assetless_icon_name = valid_script + "<key>CFBundleIconName</key><string>AppIcon</string>\n"
        violations = verifier.check_install_script(assetless_icon_name)
        self.assertTrue(
            any("CFBundleIconName without bundling Assets.car" in v for v in violations),
            violations,
        )

        with_asset_catalog = assetless_icon_name + 'cp Assets.car "$SOURCE/Contents/Resources/Assets.car"\n'
        self.assertEqual(verifier.check_install_script(with_asset_catalog), [])

        with_unpadded_png = valid_script + 'cp icon.png "$SOURCE/Contents/Resources/AppIcon.png"\n'
        violations = verifier.check_install_script(with_unpadded_png)
        self.assertTrue(
            any("AppIcon.png into Contents/Resources" in v for v in violations),
            violations,
        )

        without_lsregister_force = valid_script.replace('"$LSREGISTER" -f "$TARGET"', '"$LSREGISTER" -u "$SOURCE"')
        violations = verifier.check_install_script(without_lsregister_force)
        self.assertTrue(
            any("lsregister -f" in v for v in violations),
            violations,
        )

    def test_install_script_comment_stripping_and_plist_xml_validation(self) -> None:
        valid_lines = [
            "#!/usr/bin/env bash",
            'LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"',
            *verifier.REQUIRED_INSTALL_PLIST_KEYS,
            '"$LSREGISTER" -f "$TARGET"',
        ]
        valid_script = "\n".join(valid_lines) + "\n"

        commented_explanation = (
            valid_script
            + "# Never set CFBundleIconName without Assets.car or copy AppIcon.png into Contents/Resources\n"
        )
        self.assertEqual(verifier.check_install_script(commented_explanation), [])

        commented_out_lsregister = valid_script.replace(
            '"$LSREGISTER" -f "$TARGET"',
            '# "$LSREGISTER" -f "$TARGET"',
        )
        violations = verifier.check_install_script(commented_out_lsregister)
        self.assertTrue(
            any("lsregister -f" in v for v in violations),
            violations,
        )

        commented_out_assets = (
            valid_script
            + "<key>CFBundleIconName</key><string>AppIcon</string>\n"
            + '# cp Assets.car "$SOURCE/Contents/Resources/Assets.car"\n'
        )
        violations = verifier.check_install_script(commented_out_assets)
        self.assertTrue(
            any("CFBundleIconName without bundling Assets.car" in v for v in violations),
            violations,
        )

        usage_keys = [k for k in verifier.REQUIRED_INSTALL_PLIST_KEYS if k.startswith("NS")]
        plist_entries = [
            "  <key>CFBundleIconFile</key><string>WrongIcon</string>",
            *[
                f"  <key>{k}</key><string>{'' if k == 'NSMicrophoneUsageDescription' else 'ok'}</string>"
                for k in usage_keys
            ],
        ]
        bad_plist_script = "\n".join(
            [
                "#!/usr/bin/env bash",
                "AppIcon.icns",
                "--verify-self",
                "--smoke-test",
                '"$LSREGISTER" -f "$TARGET"',
                "cat <<'PLIST'",
                '<?xml version="1.0" encoding="UTF-8"?>',
                '<plist version="1.0"><dict>',
                *plist_entries,
                "</dict></plist>",
                "PLIST",
            ]
        )
        plist_violations = verifier.check_install_script(bad_plist_script)
        self.assertTrue(
            any("CFBundleIconFile" in v for v in plist_violations),
            plist_violations,
        )
        self.assertTrue(
            any("NSMicrophoneUsageDescription" in v for v in plist_violations),
            plist_violations,
        )

    def test_repository_rejects_native_palette_regressions(self) -> None:
        root = Path(__file__).resolve().parent.parent
        theme_path = Path("platforms/apple-shared/Sources/KoeAppleShared/DesignKit.swift")
        native_theme = (root / theme_path).read_text(encoding="utf-8")
        for before, after, violation in (
            ("accent = Color(hex: 0x242426)", "accent = Color(hex: 0xFF0000)", "approved charcoal"),
            ("textMuted = Color(hex: 0x686870)", "textMuted = Color(hex: 0xBBBBBB)", "Contrast violation: textMuted"),
        ):
            with self.subTest(token=before), tempfile.TemporaryDirectory() as tmp:
                fixture_root = Path(tmp)
                native_path = fixture_root / theme_path
                native_path.parent.mkdir(parents=True)
                native_path.write_text(native_theme, encoding="utf-8")
                legacy_path = fixture_root / "crates/koe-client-core/src/theme.rs"
                legacy_path.parent.mkdir(parents=True)
                legacy_path.write_text(LEGACY_LIGHT_THEME, encoding="utf-8")
                self.assertEqual(verifier.analyze_repository(fixture_root, "all")["violations"], [])
                native_path.write_text(native_theme.replace(before, after), encoding="utf-8")
                report = verifier.analyze_repository(fixture_root, "all")
                self.assertTrue(any(violation in v for v in report["violations"]), report["violations"])

    def test_repository_shared_theme_passes_all_principles(self) -> None:
        root = Path(__file__).resolve().parent.parent
        report = verifier.analyze_repository(root, "all")
        self.assertEqual(report["violations"], [])
        self.assertGreaterEqual(report["checked_files_count"], 1)

    def test_enforces_two_tier_scoped_observation_slice_gates(self) -> None:
        bad_snapshot_view = """
        import SwiftUI
        struct BadSnapshotView: View {
            let store: HostSessionStore
            var body: some View {
                Text(store.snapshot.section).font(.system(size: AppFontSizes.sm))
            }
        }
        """
        res_snapshot = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/SidebarView.swift",
            bad_snapshot_view,
            strict_scale=True,
        )
        self.assertTrue(
            any("reads store.snapshot directly" in v for v in res_snapshot["violations"]),
            res_snapshot["violations"],
        )

        allowed_store = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/HostSessionStore.swift",
            bad_snapshot_view,
            strict_scale=True,
        )
        self.assertEqual(allowed_store["violations"], [])

        allowed_slices = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/HostSessionSlices.swift",
            bad_snapshot_view,
            strict_scale=True,
        )
        self.assertEqual(allowed_slices["violations"], [])

        for prop in ("playback", "activeCapture", "liveCaption", "liveMinutesCoverage"):
            bad_hf_view = f"""
            import SwiftUI
            struct BadHighFreqView: View {{
                let store: HostSessionStore
                var body: some View {{
                    let _ = store.{prop}
                    Text("标题").font(.system(size: AppFontSizes.sm))
                }}
            }}
            """
            res_hf = verifier.check_ui_file(
                "platforms/apple-shared/Sources/KoeAppleShared/WorkspaceRootView.swift",
                bad_hf_view,
                strict_scale=True,
            )
            self.assertTrue(
                any("4 Hz high-frequency slice(s)" in v for v in res_hf["violations"]),
                res_hf["violations"],
            )

        for leaf_file, prop in (
            ("PlayerBarView.swift", "playback"),
            ("ActiveCaptureBar.swift", "activeCapture"),
            ("LiveCaptionBar.swift", "liveCaption"),
            ("LiveMinutesCoverageSlotView.swift", "liveMinutesCoverage"),
        ):
            compliant_leaf = f"""
            import SwiftUI
            struct LeafView: View {{
                let store: HostSessionStore
                var body: some View {{
                    let _ = store.{prop}
                    Text("叶子组件").font(.system(size: AppFontSizes.xs))
                }}
            }}
            """
            res_leaf = verifier.check_ui_file(
                f"platforms/apple-shared/Sources/KoeAppleShared/{leaf_file}",
                compliant_leaf,
                strict_scale=True,
            )
            self.assertEqual(res_leaf["violations"], [], res_leaf["violations"])

        live_minutes_parent_leak = """
        import SwiftUI
        struct LiveMinutesView: View {
            let store: HostSessionStore
            var body: some View {
                let _ = store.liveMinutesCoverage
                Text("实时纪要").font(.system(size: AppFontSizes.sm))
            }
        }
        """
        res_lm_leak = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/LiveMinutesView.swift",
            live_minutes_parent_leak,
            strict_scale=True,
        )
        self.assertTrue(
            any("4 Hz high-frequency slice(s)" in v for v in res_lm_leak["violations"]),
            res_lm_leak["violations"],
        )

        cross_leaf_leak = """
        import SwiftUI
        struct PlayerBarView: View {
            let store: HostSessionStore
            var body: some View {
                let _ = store.playback
                let _ = store.activeCapture
                Text("播放").font(.system(size: AppFontSizes.xs))
            }
        }
        """
        res_cross_leak = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/PlayerBarView.swift",
            cross_leaf_leak,
            strict_scale=True,
        )
        self.assertTrue(
            any("4 Hz high-frequency slice(s)" in v for v in res_cross_leak["violations"]),
            res_cross_leak["violations"],
        )

        macos_host_view_leak = """
        import SwiftUI
        final class HostAdapter {
            func check(store: HostSessionStore) -> String { store.snapshot.section }
        }
        struct HostBadScene: App {
            let store: HostSessionStore
            var body: some Scene {
                let _ = store.snapshot.section
                let _ = store.playback
                WindowGroup("Koe") { EmptyView() }
            }
        }
        """
        res_macos_leak = verifier.check_ui_file(
            "platforms/macos/Sources/Koe/KoeMacApp.swift",
            macos_host_view_leak,
            strict_scale=True,
        )
        self.assertTrue(
            any("reads store.snapshot directly" in v for v in res_macos_leak["violations"]),
            res_macos_leak["violations"],
        )
        self.assertTrue(
            any("4 Hz high-frequency slice(s)" in v for v in res_macos_leak["violations"]),
            res_macos_leak["violations"],
        )

        compliant_page = """
        import SwiftUI
        struct CompliantPageView: View {
            let store: HostSessionStore
            var body: some View {
                let nav = store.navigation
                Text(nav.section).font(.system(size: AppFontSizes.sm))
            }
        }
        """
        res_page = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/WorkspaceRootView.swift",
            compliant_page,
            strict_scale=True,
        )
        self.assertEqual(res_page["violations"], [])

        app_delegate_snapshot_leak = """
        import AppKit
        final class KoeAppDelegate: NSObject {
            var store: HostSessionStore?
            func check() {
                let _ = store?.snapshot.lifecycle
            }
        }
        """
        res_delegate = verifier.check_ui_file(
            "platforms/macos/Sources/Koe/KoeMacApp.swift",
            app_delegate_snapshot_leak,
            strict_scale=True,
        )
        self.assertTrue(
            any("reads store.snapshot directly" in v for v in res_delegate["violations"]),
            res_delegate["violations"],
        )

        adapter_snapshot_ok = """
        import Foundation
        final class NativeCapture {
            var store: HostSessionStore?
            func apply() {
                let _ = store?.snapshot.microphone
            }
        }
        """
        res_adapter = verifier.check_ui_file(
            "platforms/macos/Sources/Koe/NativeCapture.swift",
            adapter_snapshot_ok,
            strict_scale=True,
        )
        self.assertEqual(res_adapter["violations"], [])


if __name__ == "__main__":
    unittest.main()
