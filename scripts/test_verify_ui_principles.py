#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


def load_verifier():
    script_path = Path(__file__).resolve().parent / "verify-ui-principles.py"
    spec = importlib.util.spec_from_file_location("verify_ui_principles", script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verifier = load_verifier()


VALID_LINEAR_THEME = """
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
    pub const SURFACE_0: u32 = 0xFF1A1A1D;
    pub const BG_PANEL: u32 = 0xFF141416;
    pub const SURFACE_1: u32 = 0xFF202024;
    pub const BG_CARD: u32 = 0xFF202024;
    pub const BG_SUBTLE: u32 = 0xFF252529;
    pub const BG_CARD_HOVER: u32 = 0xFF29292E;
    pub const BG_MUTED: u32 = 0xFF2A2A30;
    pub const BORDER: u32 = 0xFF323237;
    pub const BORDER_SOFT: u32 = 0xFF2B2B30;
    pub const TEXT_PRIMARY: u32 = 0xFFEDECF2;
    pub const TEXT_SECONDARY: u32 = 0xFFBDB9C7;
    pub const TEXT_MUTED: u32 = 0xFFAAA6B5;
    pub const ACCENT: u32 = 0xFFC4B5FD;
    pub const ON_ACCENT: u32 = 0xFF251D33;
    pub const CARD_SHADOW: &[u32] = &[];
}
"""


class VerifyUiPrinciplesTest(unittest.TestCase):
    def test_accepts_approved_dark_linear_palette(self) -> None:
        res = verifier.check_theme_file(VALID_LINEAR_THEME)
        self.assertEqual(res["violations"], [])
        self.assertGreaterEqual(res["accent"]["foreground_contrast"], 4.5)

    def test_rejects_old_orange_and_blue_accents(self) -> None:
        for color in ("0xFFD9480F", "0xFF0066CC"):
            res = verifier.check_theme_file(VALID_LINEAR_THEME.replace("0xFFC4B5FD", color))
            self.assertTrue(any("approved violet" in v for v in res["violations"]), res["violations"])

    def test_rejects_unreadable_text_and_action_foreground(self) -> None:
        for before, after in (("0xFFAAA6B5", "0xFF444444"), ("0xFF251D33", "0xFFEDECF2")):
            res = verifier.check_theme_file(VALID_LINEAR_THEME.replace(before, after))
            self.assertTrue(any("contrast" in v for v in res["violations"]), res["violations"])

    def test_rejects_light_surface_and_non_empty_shadow(self) -> None:
        res = verifier.check_theme_file(VALID_LINEAR_THEME.replace("0xFF1A1A1D", "0xFFFAFAFA"))
        self.assertTrue(any("dark" in v for v in res["violations"]), res["violations"])
        res = verifier.check_theme_file(VALID_LINEAR_THEME.replace("&[]", "&[0x11000000]"))
        self.assertTrue(any("CARD_SHADOW" in v for v in res["violations"]), res["violations"])

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

    def test_repository_shared_theme_passes_all_principles(self) -> None:
        root = Path(__file__).resolve().parent.parent
        report = verifier.analyze_repository(root, "all")
        self.assertEqual(report["violations"], [])
        self.assertGreaterEqual(report["checked_files_count"], 1)


if __name__ == "__main__":
    unittest.main()
