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


VALID_VECTA_THEME = """
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
    pub const SURFACE_0: u32 = 0xFFFAFAFA;
    pub const BG_PANEL: u32 = 0xFFF0F0F2;
    pub const SURFACE_1: u32 = 0xFFF0F0F2;
    pub const BG_CARD: u32 = 0xFFFFFFFF;
    pub const BG_SUBTLE: u32 = 0xFFE6E6E9;
    pub const BG_CARD_HOVER: u32 = 0xFFDADADD;
    pub const BG_MUTED: u32 = 0xFFD1D1D5;
    pub const BORDER: u32 = 0xFFCCCCD2;
    pub const BORDER_SOFT: u32 = 0xFFE2E2E7;
    pub const TEXT_PRIMARY: u32 = 0xFF171719;
    pub const TEXT_SECONDARY: u32 = 0xFF515157;
    pub const TEXT_MUTED: u32 = 0xFF626269;
    pub const ACCENT: u32 = 0xFFD9480F;
    pub const ORANGE_BRAND: u32 = 0xFFFF5F05;
    pub const ORANGE_ACTION: u32 = 0xFFD9480F;
    pub const ORANGE_DEEP: u32 = 0xFF9A3412;
    pub const ORANGE_TINT: u32 = 0xFFFFF1E6;
    pub const ORANGE_BORDER: u32 = 0xFFFDBA8C;
    pub const CARD_SHADOW: &[u32] = &[];
}
pub struct AIVisualEditorialPalette;
impl AIVisualEditorialPalette {
    pub const CORE_CONCLUSION_BG: u32 = 0xFFFCEEE5;
    pub const ACTION_ITEMS_BG: u32 = 0xFFDFEFCD;
    pub const RISKS_BG: u32 = 0xFFFAECEF;
    pub const TIMELINE_BG: u32 = 0xFFFAF7EB;
    pub const ENTITIES_BG: u32 = 0xFFECF6FA;
    pub const OPEN_QUESTIONS_BG: u32 = 0xFFECEFFA;
}
"""


class VerifyUiPrinciplesTest(unittest.TestCase):
    def test_accepts_vecta_90_8_2_illinois_orange_theme(self) -> None:
        res = verifier.check_theme_file(VALID_VECTA_THEME)
        self.assertEqual(res["violations"], [])
        self.assertGreaterEqual(res["accent"]["white_contrast"], 4.25)

    def test_rejects_legacy_terracotta_and_enterprise_blue_accents(self) -> None:
        terracotta_theme = VALID_VECTA_THEME.replace(
            "pub const ACCENT: u32 = 0xFFD9480F;",
            "pub const ACCENT: u32 = 0xFFA4472B;",
        )
        res = verifier.check_theme_file(terracotta_theme)
        self.assertTrue(
            any("legacy terracotta" in v for v in res["violations"]),
            res["violations"],
        )

        enterprise_blue_theme = VALID_VECTA_THEME.replace(
            "pub const ACCENT: u32 = 0xFFD9480F;",
            "pub const ACCENT: u32 = 0xFF0066CC;",
        )
        res_blue = verifier.check_theme_file(enterprise_blue_theme)
        self.assertTrue(
            any("legacy bright blue" in v for v in res_blue["violations"]),
            res_blue["violations"],
        )

    def test_rejects_low_contrast_brand_orange_used_as_action_accent(self) -> None:
        bad_accent_theme = VALID_VECTA_THEME.replace(
            "pub const ACCENT: u32 = 0xFFD9480F;",
            "pub const ACCENT: u32 = 0xFFFF5F05;",
        )
        res = verifier.check_theme_file(bad_accent_theme)
        self.assertTrue(
            any("contrast" in v for v in res["violations"]),
            res["violations"],
        )

    def test_rejects_missing_editorial_palette_fills_and_non_empty_shadow(self) -> None:
        missing_fill_theme = VALID_VECTA_THEME.replace("0xFFECEFFA", "0xFF123456")
        res = verifier.check_theme_file(missing_fill_theme)
        self.assertTrue(
            any("AIVisualEditorialPalette" in v for v in res["violations"]),
            res["violations"],
        )

        shadow_theme = VALID_VECTA_THEME.replace(
            "pub const CARD_SHADOW: &[u32] = &[];",
            "pub const CARD_SHADOW: &[u32] = &[0x11000000];",
        )
        res_shadow = verifier.check_theme_file(shadow_theme)
        self.assertTrue(
            any("CARD_SHADOW" in v or "cardShadow" in v for v in res_shadow["violations"]),
            res_shadow["violations"],
        )

    def test_catches_font_size_sprawl_middle_dots_uppercase_and_red_buttons(self) -> None:
        bad_ui = """
        Widget build(BuildContext context) {
          final a = Text('录音中 · 打开'.toUpperCase(), style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic));
          final b = Text('二', style: TextStyle(fontSize: 12));
          final c = Text('三', style: TextStyle(fontSize: 13));
          final d = Text('四', style: TextStyle(fontSize: 15));
          final e = Text('五', style: TextStyle(fontSize: 20));
          final btn = FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            onPressed: () {},
            child: Text('立即开启'),
          );
          return Column(children: [a, b, c, d, e, btn]);
        }
        """
        res = verifier.check_ui_file("lib/ui/screens/sample.dart", bad_ui, strict_scale=True)
        joined = "\n".join(res["violations"])
        self.assertIn("distinct font sizes", joined)
        self.assertIn("off-scale font sizes", joined)
        self.assertIn("middle dot", joined)
        self.assertIn("FontStyle.italic", joined)
        self.assertIn(".toUpperCase()", joined)
        self.assertIn("pushy marketing verb", joined)
        self.assertIn("full-red destructive FilledButton", joined)

    def test_accepts_clean_ui_file_within_4_size_scale(self) -> None:
        clean_ui = """
        Widget build(BuildContext context) {
          return Column(
            children: const [
              Text('录音库', style: TextStyle(fontSize: 22)),
              Text('连接录音豆', style: TextStyle(fontSize: 16)),
              Text('正文段落', style: TextStyle(fontSize: 14)),
              Text('12:30', style: TextStyle(fontSize: 12)),
            ],
          );
        }
        """
        res = verifier.check_ui_file("lib/ui/screens/home_screen.dart", clean_ui, strict_scale=True)
        self.assertEqual(res["violations"], [])

    def test_parses_app_font_sizes_tokens_and_rejects_unknown_token(self) -> None:
        token_ui = """
        Widget build(BuildContext context) {
          return Column(
            children: const [
              Text('标题', style: TextStyle(fontSize: AppFontSizes.lg)),
              Text('小节', style: TextStyle(fontSize: AppFontSizes.md)),
              Text('正文', style: TextStyle(fontSize: AppFontSizes.sm)),
              Text('说明', style: TextStyle(fontSize: AppFontSizes.xs)),
            ],
          );
        }
        """
        res = verifier.check_ui_file("lib/ui/screens/today_screen.dart", token_ui, strict_scale=True)
        self.assertEqual(res["violations"], [])
        self.assertEqual(res["distinct_font_sizes"], [12.0, 14.0, 16.0, 22.0])

        bad_token_ui = token_ui.replace("AppFontSizes.lg", "AppFontSizes.xxl")
        res_bad = verifier.check_ui_file("lib/ui/screens/today_screen.dart", bad_token_ui, strict_scale=True)
        self.assertTrue(
            any("unknown AppFontSizes token" in v for v in res_bad["violations"]),
            res_bad["violations"],
        )

    def test_rejects_dynamic_font_size_reversible_trash_dialog_and_legacy_colors(self) -> None:
        adversarial_ui = """
        Widget build(BuildContext context) {
          final s = Theme.of(context).textTheme.headlineSmall;
          final a = Text('85%', style: TextStyle(fontSize: size * 0.21, color: Colors.green));
          final b = Text('移到回收站？', style: TextStyle(color: const Color(0xffb66c50)));
          final c = Text('立即同步');
          return Column(children: [a, b, c]);
        }
        """
        res = verifier.check_ui_file("lib/ui/screens/sample.dart", adversarial_ui, strict_scale=True)
        joined = "\n".join(res["violations"])
        self.assertIn(16.0, res["distinct_font_sizes"])
        self.assertIn("dynamic off-scale fontSize expression", joined)
        self.assertIn("移到回收站？", joined)
        self.assertIn("legacy terracotta or unstyled Material color", joined)
        self.assertIn("pushy marketing verb", joined)

    def test_repository_pure_rust_gpui_passes_all_principles(self) -> None:
        root = Path(__file__).resolve().parent.parent
        report = verifier.analyze_repository(root, "all")
        self.assertEqual(report["violations"], [])
        self.assertGreaterEqual(report["checked_files_count"], 2)


if __name__ == "__main__":
    unittest.main()
