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


VALID_LIGHT_THEME = (
    Path(__file__).resolve().parent.parent
    / "platforms/apple-shared/Sources/KoeAppleShared/DesignKit.swift"
).read_text(encoding="utf-8")

VALID_ANDROID_THEME = (
    Path(__file__).resolve().parent.parent
    / "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/theme/KoeTheme.kt"
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
        bad_mac_app_fallback = """
        import AppKit
        enum KoeWindowPresenter {
            static func isWorkspaceWindow(_ window: NSWindow) -> Bool { true }
            static func open() {
                let w = NSApp?.windows.first(where: { isWorkspaceWindow($0) }) ?? NSApp?.windows.first
                _ = w
            }
        }
        """
        safe_mac_app_comment = """
        import AppKit
        enum KoeWindowPresenter {
            static func isWorkspaceWindow(_ window: NSWindow) -> Bool { true }
            static func open() {
                // Avoid unfiltered NSApp?.windows.first which matches NSStatusBarWindow
                let w = NSApp?.windows.first(where: { isWorkspaceWindow($0) && $0.isVisible })
                _ = w
            }
        }
        """
        for mac_path in (
            "platforms/macos/Sources/Koe/KoeMacApp.swift",
            "platforms/macos/Sources/Koe/KoeWindowPresenter.swift",
        ):
            res_mac = verifier.check_ui_file(
                mac_path,
                bad_mac_app,
                strict_scale=True,
            )
            self.assertTrue(
                any("isWorkspaceWindow" in v for v in res_mac["violations"]),
                (mac_path, res_mac["violations"]),
            )
            res_fallback = verifier.check_ui_file(
                mac_path,
                bad_mac_app_fallback,
                strict_scale=True,
            )
            self.assertTrue(
                any("isWorkspaceWindow" in v for v in res_fallback["violations"]),
                (mac_path, res_fallback["violations"]),
            )
            res_safe = verifier.check_ui_file(
                mac_path,
                safe_mac_app_comment,
                strict_scale=True,
            )
            self.assertEqual(res_safe["violations"], [], (mac_path, res_safe["violations"]))

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
            any("NSMicrophoneUsageDescription" in v for v in install_violations),
            install_violations,
        )
        for removed in (
            "NSLocalNetworkUsageDescription",
            "NSCalendarsUsageDescription",
            "NSCalendarsFullAccessUsageDescription",
            "NSRemindersUsageDescription",
            "NSRemindersFullAccessUsageDescription",
        ):
            self.assertNotIn(removed, verifier.REQUIRED_INSTALL_PLIST_KEYS)

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
                self.assertEqual(verifier.analyze_repository(fixture_root, "all")["violations"], [])
                native_path.write_text(native_theme.replace(before, after), encoding="utf-8")
                report = verifier.analyze_repository(fixture_root, "all")
                self.assertTrue(any(violation in v for v in report["violations"]), report["violations"])

    def test_android_theme_palette_contrast_and_font_scale_contracts(self) -> None:
        res_valid = verifier.check_android_theme_file(VALID_ANDROID_THEME)
        self.assertEqual(res_valid["violations"], [])
        self.assertGreaterEqual(res_valid["accent"]["foreground_contrast"], 4.5)

        for before, after, expected in (
            ("accent = Color(0xFF242426)", "accent = Color(0xFFD9480F)", "approved charcoal"),
            ("textMuted = Color(0xFF686870)", "textMuted = Color(0xFFBBBBBB)", "Contrast violation: textMuted"),
            ("textMuted = Color(0xFF94949E)", "textMuted = Color(0xFF3A3A40)", "Contrast violation: textMuted"),
            ("onAccent = Color(0xFF0E0E10)", "onAccent = Color(0xFFE0E0E4)", "Contrast violation: onAccent"),
            ("surface0 = Color(0xFFFFFFFF)", "surface0 = Color(0xFF1A1A1D)", "light surface"),
            ("textPrimary = Color(0xFF202022)", "textPrimary = Color(0x00202022)", "opaque 8-digit ARGB"),
            ("accent = Color(0xFF242426)", "accent = Color(0x242426)", "opaque 8-digit ARGB"),
            ("accent = Color(0xFF242426)", "accent = Color(0xF242426)", "opaque 8-digit ARGB"),
            ("val lg = 22.sp", "val lg = 28.sp", "KoeFontSizes"),
        ):
            with self.subTest(before=before):
                mutated = VALID_ANDROID_THEME.replace(before, after, 1)
                self.assertNotEqual(mutated, VALID_ANDROID_THEME)
                res = verifier.check_android_theme_file(mutated)
                self.assertTrue(any(expected in v for v in res["violations"]), res["violations"])

        typed_and_long_theme = (
            VALID_ANDROID_THEME
            .replace("private val LightKoePalette = KoePalette(", "private val LightKoePalette: KoePalette = KoePalette(", 1)
            .replace("accent = Color(0xFF242426)", "accent = Color(0xFF242426L)", 1)
        )
        self.assertEqual(verifier.check_android_theme_file(typed_and_long_theme)["violations"], [])

    def test_catches_scoped_observation_inside_string_interpolations(self) -> None:
        swift_interpolated = r'''
        import SwiftUI
        struct InterpView: View {
            let store: HostSessionStore
            var body: some View {
                Text("gen=\(store.snapshot.generation) playing=\(store.playback.isPlaying)")
                    .font(.system(size: AppFontSizes.sm))
            }
        }
        '''
        for path in (
            "platforms/apple-shared/Sources/KoeAppleShared/InterpView.swift",
            "platforms/ios/App/Sources/InterpView.swift",
            "platforms/macos/Sources/Koe/InterpView.swift",
        ):
            with self.subTest(path=path):
                res = verifier.check_ui_file(path, swift_interpolated, strict_scale=True)
                self.assertTrue(
                    any("reads store.snapshot directly" in v for v in res["violations"]),
                    (path, res["violations"]),
                )
                self.assertTrue(
                    any("4 Hz high-frequency slice(s)" in v for v in res["violations"]),
                    (path, res["violations"]),
                )

        kotlin_interpolated = '''
        package com.semanticcraft.koe.ui
        fun InterpScreen(store: HostSessionStore) {
            val label = "gen=${store.snapshot.generation} playing=${store.playback.isPlaying}"
            println(label)
        }
        '''
        res_kt = verifier.check_ui_file(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/InterpScreen.kt",
            kotlin_interpolated,
            strict_scale=True,
        )
        self.assertTrue(any("reads store.snapshot directly" in v for v in res_kt["violations"]), res_kt["violations"])
        self.assertTrue(any("4 Hz high-frequency slice(s)" in v for v in res_kt["violations"]), res_kt["violations"])

    def test_mask_source_handles_kotlin_char_literals_raw_quote_runs_and_swift_raw_strings(self) -> None:
        kotlin_chars_and_raw = '''
        package com.semanticcraft.koe.core
        private val INVALID = setOf('/', '\\\\', '\\'', '"', '<')
        private val RAW = """hello""""
        import androidx.compose.runtime.Composable
        '''
        res_kt = verifier.check_ui_file(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/SafHelper.kt",
            kotlin_chars_and_raw,
            strict_scale=True,
        )
        self.assertTrue(
            any("androidx.compose" in v for v in res_kt["violations"]),
            res_kt["violations"],
        )

        swift_raw_strings = '''
        import Foundation
        public enum Patterns {
            static let a = #"quote " and trailing \\"#
            static let b = ##"escaped \\##" still inside and import SwiftUI"##
            static let c = #"""
            import AppKit
            """#
        }
        import UIKit
        '''
        res_swift = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleCore/Patterns.swift",
            swift_raw_strings,
            strict_scale=True,
        )
        joined = "\n".join(res_swift["violations"])
        self.assertIn("UIKit", joined)
        self.assertNotIn("SwiftUI", joined)
        self.assertNotIn("AppKit", joined)

        android_theme_rel = Path(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/theme/KoeTheme.kt"
        )
        swift_theme_rel = Path("platforms/apple-shared/Sources/KoeAppleShared/DesignKit.swift")
        with tempfile.TemporaryDirectory() as tmp:
            fixture_root = Path(tmp)
            (fixture_root / swift_theme_rel).parent.mkdir(parents=True)
            (fixture_root / swift_theme_rel).write_text(VALID_LIGHT_THEME, encoding="utf-8")
            (fixture_root / android_theme_rel).parent.mkdir(parents=True)
            (fixture_root / android_theme_rel).write_text(
                VALID_ANDROID_THEME.replace("textMuted = Color(0xFF686870)", "textMuted = Color(0xFFBBBBBB)", 1),
                encoding="utf-8",
            )
            report = verifier.analyze_repository(fixture_root, "all")
            self.assertTrue(
                any("Contrast violation: textMuted" in v and "Android LightKoePalette" in v for v in report["violations"]),
                report["violations"],
            )

    def test_code_only_checks_ignore_comments_and_drop_dead_red_button_fields(self) -> None:
        commented_swift = """
        import SwiftUI
        struct CommentedView: View {
            // Avoid .italic(), .uppercased(), legacy 0xFFB66C50, .buttonStyle(.plain), TextField("x")
            /*
             * .italic()
             * .uppercased()
             * 0xFFB66C50
             * .buttonStyle(.plain)
             * TextField("blocked", text: $x)
             */
            var body: some View {
                Text("正文").font(.system(size: AppFontSizes.sm))
            }
        }
        """
        res = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/CommentedView.swift",
            commented_swift,
            strict_scale=True,
        )
        self.assertEqual(res["violations"], [], res["violations"])
        self.assertNotIn("full_red_buttons", res)

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

        comment_brace_bypass = """
        import AppKit
        final class KoeAppDelegate: NSObject {
            var store: HostSessionStore?
            func check() {
                // }
                /* } /* } */ */
                let _ = store?.snapshot.lifecycle
            }
        }
        """
        res_comment_brace = verifier.check_ui_file(
            "platforms/macos/Sources/Koe/KoeMacApp.swift",
            comment_brace_bypass,
            strict_scale=True,
        )
        self.assertTrue(
            any("reads store.snapshot directly" in v for v in res_comment_brace["violations"]),
            res_comment_brace["violations"],
        )

        for target_path, snippet in (
            (
                "platforms/macos/Sources/Koe/KoeMacApp.swift",
                """
                import AppKit
                extension KoeAppDelegate {
                    func helper() { let _ = store?.snapshot.device }
                }
                """,
            ),
            (
                "platforms/macos/Sources/Koe/KoeMacApp.swift",
                """
                import AppKit
                public enum KoeWindowPresenter {
                    static func open(store: HostSessionStore?) { let _ = store?.snapshot.lifecycle }
                }
                """,
            ),
            (
                "platforms/macos/Sources/Koe/KoeWindowPresenter.swift",
                """
                import AppKit
                public enum KoeWindowPresenter {
                    static func open(store: HostSessionStore?) { let _ = store?.snapshot.lifecycle }
                }
                """,
            ),
            (
                "platforms/macos/Sources/Koe/KoeWindowPresenter.swift",
                """
                import AppKit
                extension KoeWindowPresenter {
                    static func helper(store: HostSessionStore?) { let _ = store?.snapshot.lifecycle }
                }
                """,
            ),
        ):
            res_ext = verifier.check_ui_file(
                target_path,
                snippet,
                strict_scale=True,
            )
            self.assertTrue(
                any("reads store.snapshot directly" in v for v in res_ext["violations"]),
                (target_path, res_ext["violations"]),
            )

    def test_rejects_foreach_offset_identity_churn_outside_comments(self) -> None:
        for bad_foreach in (
            """
            import SwiftUI
            struct OffsetView: View {
                let items: [String]
                var body: some View {
                    ForEach(Array(items.enumerated()), id: \\.offset) { _, text in
                        Text(text).font(.system(size: AppFontSizes.sm))
                    }
                }
            }
            """,
            """
            import SwiftUI
            struct DirectOffsetView: View {
                let items: [(offset: Int, element: String)]
                var body: some View {
                    ForEach(items, id: \\.offset) { item in
                        Text(item.element).font(.system(size: AppFontSizes.sm))
                    }
                }
            }
            """,
        ):
            res = verifier.check_ui_file(
                "platforms/apple-shared/Sources/KoeAppleShared/OffsetView.swift",
                bad_foreach,
                strict_scale=True,
            )
            self.assertTrue(
                any("id: \\.offset" in v for v in res["violations"]),
                res["violations"],
            )

        commented_offset = """
        import SwiftUI
        struct SafeView: View {
            let items: [String]
            var body: some View {
                // Never use ForEach(items, id: \\.offset)
                /* ForEach(Array(items.enumerated()), id: \\.offset) */
                Text("ok").font(.system(size: AppFontSizes.sm))
            }
        }
        """
        res_ok = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleShared/SafeView.swift",
            commented_offset,
            strict_scale=True,
        )
        self.assertEqual(res_ok["violations"], [])

    def test_enforces_koe_apple_core_ui_framework_and_slice_boundaries(self) -> None:
        for framework in ("AppKit", "SwiftUI", "UIKit"):
            for snippet in (
                f"import Foundation\nimport {framework}\npublic struct CoreModel {{}}\n",
                f"@_exported import {framework}\npublic struct CoreModel {{}}\n",
                f"import struct {framework}.Color\npublic struct CoreModel {{}}\n",
            ):
                res = verifier.check_ui_file(
                    "platforms/apple-shared/Sources/KoeAppleCore/CoreModel.swift",
                    snippet,
                    strict_scale=True,
                )
                self.assertTrue(
                    any(framework in v and "KoeAppleCore" in v for v in res["violations"]),
                    (framework, snippet, res["violations"]),
                )

        comment_and_string_imports = '''
        import Foundation
        // import SwiftUI
        /* import AppKit
           /* import UIKit */ */
        public enum DocStrings {
            static let single = "import SwiftUI and import AppKit"
            static let multi = """
            import UIKit
            import SwiftUI
            """
        }
        '''
        res_safe = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleCore/DocStrings.swift",
            comment_and_string_imports,
            strict_scale=True,
        )
        self.assertEqual(res_safe["violations"], [], res_safe["violations"])

        core_snapshot_leak = """
        import Foundation
        struct CoreHelper {
            func section(_ store: HostSessionStore) -> String { store.snapshot.section }
        }
        """
        res_core_snap = verifier.check_ui_file(
            "platforms/apple-shared/Sources/KoeAppleCore/CoreHelper.swift",
            core_snapshot_leak,
            strict_scale=True,
        )
        self.assertTrue(
            any("reads store.snapshot directly" in v for v in res_core_snap["violations"]),
            res_core_snap["violations"],
        )

        for prop in ("playback", "activeCapture", "liveCaption", "liveMinutesCoverage"):
            core_hf_leak = f"""
            import Foundation
            struct CoreHelper {{
                func check(_ store: HostSessionStore) {{ let _ = store.{prop} }}
            }}
            """
            res_core_hf = verifier.check_ui_file(
                "platforms/apple-shared/Sources/KoeAppleCore/CoreHelper.swift",
                core_hf_leak,
                strict_scale=True,
            )
            self.assertTrue(
                any("4 Hz high-frequency slice(s)" in v for v in res_core_hf["violations"]),
                (prop, res_core_hf["violations"]),
            )

        for allowed_core in ("HostSessionStore.swift", "HostSessionSlices.swift"):
            res_allowed = verifier.check_ui_file(
                f"platforms/apple-shared/Sources/KoeAppleCore/{allowed_core}",
                core_snapshot_leak,
                strict_scale=True,
            )
            self.assertEqual(res_allowed["violations"], [], (allowed_core, res_allowed["violations"]))

    def test_enforces_ios_app_scoped_observation_and_leaf_slice_ownership(self) -> None:
        ios_snapshot_view = """
        import SwiftUI
        struct IOSTodayView: View {
            let store: HostSessionStore
            var body: some View {
                Text(store.snapshot.section).font(.system(size: AppFontSizes.sm))
            }
        }
        """
        res_ios_snap = verifier.check_ui_file(
            "platforms/ios/App/Sources/IOSTodayView.swift",
            ios_snapshot_view,
            strict_scale=True,
        )
        self.assertTrue(
            any("reads store.snapshot directly" in v for v in res_ios_snap["violations"]),
            res_ios_snap["violations"],
        )

        ios_app_leak = """
        import SwiftUI
        struct KoeIOSApp: App {
            let store: HostSessionStore
            var body: some Scene {
                let _ = store.snapshot.section
                let _ = store.playback
                WindowGroup { EmptyView() }
            }
        }
        """
        res_ios_app = verifier.check_ui_file(
            "platforms/ios/App/Sources/KoeIOSApp.swift",
            ios_app_leak,
            strict_scale=True,
        )
        self.assertTrue(
            any("reads store.snapshot directly" in v for v in res_ios_app["violations"]),
            res_ios_app["violations"],
        )
        self.assertTrue(
            any("4 Hz high-frequency slice(s)" in v for v in res_ios_app["violations"]),
            res_ios_app["violations"],
        )

        ios_adapter_ok = """
        import Foundation
        final class IOSNativeCapture {
            var store: HostSessionStore?
            func apply() {
                let _ = store?.snapshot.microphone
            }
        }
        """
        res_ios_adapter = verifier.check_ui_file(
            "platforms/ios/App/Sources/IOSNativeCapture.swift",
            ios_adapter_ok,
            strict_scale=True,
        )
        self.assertEqual(res_ios_adapter["violations"], [], res_ios_adapter["violations"])

        for prop in ("playback", "activeCapture", "liveCaption", "liveMinutesCoverage"):
            bad_ios_page = f"""
            import SwiftUI
            struct IOSWorkspaceView: View {{
                let store: HostSessionStore
                var body: some View {{
                    let _ = store.{prop}
                    Text("工作区").font(.system(size: AppFontSizes.sm))
                }}
            }}
            """
            res_bad_page = verifier.check_ui_file(
                "platforms/ios/App/Sources/IOSWorkspaceView.swift",
                bad_ios_page,
                strict_scale=True,
            )
            self.assertTrue(
                any("4 Hz high-frequency slice(s)" in v for v in res_bad_page["violations"]),
                (prop, res_bad_page["violations"]),
            )

        for leaf_file, prop in (
            ("IOSPlayerBarView.swift", "playback"),
            ("IOSActiveCaptureBar.swift", "activeCapture"),
            ("IOSLiveCaptionBar.swift", "liveCaption"),
            ("IOSLiveMinutesCoverageSlotView.swift", "liveMinutesCoverage"),
        ):
            compliant_ios_leaf = f"""
            import SwiftUI
            struct IOSLeafView: View {{
                let store: HostSessionStore
                var body: some View {{
                    let _ = store.{prop}
                    Text("叶子组件").font(.system(size: AppFontSizes.xs))
                }}
            }}
            """
            res_leaf = verifier.check_ui_file(
                f"platforms/ios/App/Sources/{leaf_file}",
                compliant_ios_leaf,
                strict_scale=True,
            )
            self.assertEqual(res_leaf["violations"], [], (leaf_file, res_leaf["violations"]))

        ios_cross_leaf = """
        import SwiftUI
        struct IOSPlayerBarView: View {
            let store: HostSessionStore
            var body: some View {
                let _ = store.playback
                let _ = store.activeCapture
                Text("播放").font(.system(size: AppFontSizes.xs))
            }
        }
        """
        res_ios_cross = verifier.check_ui_file(
            "platforms/ios/App/Sources/IOSPlayerBarView.swift",
            ios_cross_leaf,
            strict_scale=True,
        )
        self.assertTrue(
            any("4 Hz high-frequency slice(s)" in v for v in res_ios_cross["violations"]),
            res_ios_cross["violations"],
        )

    def test_enforces_kotlin_copy_style_line_limit_and_core_ui_boundaries(self) -> None:
        bad_kotlin = """
        package com.semanticcraft.koe.ui

        fun SampleLabel(): String {
            val a = "录音中 · 打开".uppercase()
            val b = "立即开启"
            val c = "移到回收站？"
            return a + b + c
        }
        """
        res_bad = verifier.check_ui_file(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/SampleLabel.kt",
            bad_kotlin,
            strict_scale=True,
        )
        joined = "\n".join(res_bad["violations"])
        self.assertIn("middle dot", joined)
        self.assertIn("uppercase", joined.lower())
        self.assertIn("pushy marketing verb", joined)
        self.assertIn("移到回收站？", joined)

        oversized_kt = "\n".join(["// line"] * 505)
        res_oversized = verifier.check_ui_file(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/Oversized.kt",
            oversized_kt,
            strict_scale=True,
        )
        self.assertTrue(
            any("max is 500 lines" in v for v in res_oversized["violations"]),
            res_oversized["violations"],
        )

        for forbidden_import in (
            "import androidx.compose.runtime.Composable",
            "import androidx.compose.material3.Text",
            "import android.widget.Toast",
            "import android.view.View",
        ):
            snippet = f"package com.semanticcraft.koe.core\n{forbidden_import}\nclass CoreModel\n"
            res_core = verifier.check_ui_file(
                "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/CoreModel.kt",
                snippet,
                strict_scale=True,
            )
            self.assertTrue(
                any("com.semanticcraft.koe.core" in v or "core" in v.lower() for v in res_core["violations"]),
                (forbidden_import, res_core["violations"]),
            )

        safe_core = '''
        package com.semanticcraft.koe.core

        // import androidx.compose.runtime.Composable
        /* import android.widget.Toast
           /* import android.view.View */ */
        object CoreDocs {
            const val single = "import androidx.compose.ui.Modifier"
            val raw = """
                import android.widget.TextView
                import android.view.Surface
            """.trimIndent()
        }
        '''
        res_safe_core = verifier.check_ui_file(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/CoreDocs.kt",
            safe_core,
            strict_scale=True,
        )
        self.assertEqual(res_safe_core["violations"], [], res_safe_core["violations"])

    def test_enforces_android_ui_scoped_observation_and_leaf_slice_ownership(self) -> None:
        for expr in ("store.snapshot.section", "store?.snapshot?.section"):
            bad_snapshot_ui = f"""
            package com.semanticcraft.koe.ui

            fun TodayScreen(store: HostSessionStore) {{
                val s = {expr}
                println(s)
            }}
            """
            res_snap = verifier.check_ui_file(
                "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/TodayScreen.kt",
                bad_snapshot_ui,
                strict_scale=True,
            )
            self.assertTrue(
                any("reads store.snapshot directly" in v for v in res_snap["violations"]),
                (expr, res_snap["violations"]),
            )

        for prop in ("playback", "activeCapture", "liveCaption", "liveMinutesCoverage"):
            bad_page = f"""
            package com.semanticcraft.koe.ui

            fun WorkspaceScreen(store: HostSessionStore) {{
                val slice = store.{prop}
                println(slice)
            }}
            """
            res_page = verifier.check_ui_file(
                "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/WorkspaceScreen.kt",
                bad_page,
                strict_scale=True,
            )
            self.assertTrue(
                any("4 Hz high-frequency slice(s)" in v for v in res_page["violations"]),
                (prop, res_page["violations"]),
            )

        for leaf_file, prop in (
            ("AndroidPlayerBar.kt", "playback"),
            ("AndroidActiveCaptureBar.kt", "activeCapture"),
            ("AndroidLiveCaptionBar.kt", "liveCaption"),
            ("AndroidLiveMinutesCoverageSlot.kt", "liveMinutesCoverage"),
        ):
            compliant_leaf = f"""
            package com.semanticcraft.koe.ui

            fun LeafBar(store: HostSessionStore) {{
                val slice = store.{prop}
                println(slice)
            }}
            """
            res_leaf = verifier.check_ui_file(
                f"platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/{leaf_file}",
                compliant_leaf,
                strict_scale=True,
            )
            self.assertEqual(res_leaf["violations"], [], (leaf_file, res_leaf["violations"]))

        cross_leaf = """
        package com.semanticcraft.koe.ui

        fun AndroidPlayerBar(store: HostSessionStore) {
            val a = store.playback
            val b = store.activeCapture
            println("$a $b")
        }
        """
        res_cross = verifier.check_ui_file(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/AndroidPlayerBar.kt",
            cross_leaf,
            strict_scale=True,
        )
        self.assertTrue(
            any("4 Hz high-frequency slice(s)" in v for v in res_cross["violations"]),
            res_cross["violations"],
        )

        compliant_page = """
        package com.semanticcraft.koe.ui

        // Never read store.snapshot or store.playback here
        fun TodayScreen(store: HostSessionStore) {
            val today = store.today
            val nav = store.navigation
            println("$today $nav")
        }
        """
        res_ok = verifier.check_ui_file(
            "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/TodayScreen.kt",
            compliant_page,
            strict_scale=True,
        )
        self.assertEqual(res_ok["violations"], [], res_ok["violations"])

    def test_analyze_repository_scans_android_kotlin_and_skips_build_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture_root = Path(tmp)
            theme_path = fixture_root / "platforms/apple-shared/Sources/KoeAppleShared/DesignKit.swift"
            theme_path.parent.mkdir(parents=True)
            theme_path.write_text(VALID_LIGHT_THEME, encoding="utf-8")

            clean_kt = fixture_root / "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/Clean.kt"
            clean_kt.parent.mkdir(parents=True)
            clean_kt.write_text("package com.semanticcraft.koe.core\nclass Clean\n", encoding="utf-8")

            ignored_build = fixture_root / "platforms/android/gradle-app/app/build/generated/Ignored.kt"
            ignored_build.parent.mkdir(parents=True)
            ignored_build.write_text('val bad = "a · b".uppercase()\n', encoding="utf-8")

            ignored_gradle = fixture_root / "platforms/android/gradle-app/.gradle/cache/Ignored.kt"
            ignored_gradle.parent.mkdir(parents=True)
            ignored_gradle.write_text('val bad = "a · b".uppercase()\n', encoding="utf-8")

            report_clean = verifier.analyze_repository(fixture_root, "all")
            self.assertEqual(report_clean["violations"], [], report_clean["violations"])
            checked_paths = {f["file"] for f in report_clean["files"]}
            self.assertIn(
                "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/Clean.kt",
                checked_paths,
            )

            bad_kt = fixture_root / "platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/ui/Bad.kt"
            bad_kt.parent.mkdir(parents=True)
            bad_kt.write_text('package com.semanticcraft.koe.ui\nval x = "a · b".uppercase()\n', encoding="utf-8")

            report_bad = verifier.analyze_repository(fixture_root, "all")
            self.assertTrue(
                any("middle dot" in v for v in report_bad["violations"]),
                report_bad["violations"],
            )
            self.assertTrue(
                any("uppercase" in v.lower() for v in report_bad["violations"]),
                report_bad["violations"],
            )


if __name__ == "__main__":
    unittest.main()
