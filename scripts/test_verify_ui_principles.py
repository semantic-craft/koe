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


class VerifyUiPrinciplesTest(unittest.TestCase):
    def test_rejects_terracotta_and_enterprise_blue_accents(self) -> None:
        terracotta_theme = """
        class AppFontSizes { static const double xs = 12; }
        class AppRadii { static double concentric(double outer, double gap) => outer - gap; }
        class AppColors {
          static const surface0 = Color(0xFFF5F4F0);
          static const textMuted = Color(0xFF6E6C65);
          static const accent = Color(0xFFA4472B);
          static List<BoxShadow> get cardShadow => const [];
        }
        """
        res = verifier.check_theme_file(terracotta_theme)
        self.assertTrue(
            any("orange/terracotta" in v for v in res["violations"]),
            res["violations"],
        )

        enterprise_blue_theme = terracotta_theme.replace("0xFFA4472B", "0xFF0066CC")
        res_blue = verifier.check_theme_file(enterprise_blue_theme)
        self.assertTrue(
            any("legacy bright blue" in v for v in res_blue["violations"]),
            res_blue["violations"],
        )

    def test_rejects_cold_blue_gray_surfaces(self) -> None:
        cold_gray_theme = """
        class AppFontSizes { static const double xs = 12; }
        class AppRadii { static double concentric(double outer, double gap) => outer - gap; }
        class AppColors {
          static const surface0 = Color(0xFFF0F2F5);
          static const textMuted = Color(0xFF6E6C65);
          static const accent = Color(0xFF2E5E4E);
          static List<BoxShadow> get cardShadow => const [];
        }
        """
        res = verifier.check_theme_file(cold_gray_theme)
        self.assertTrue(
            any("not a warm neutral gray" in v for v in res["violations"]),
            res["violations"],
        )

    def test_accepts_bamboo_green_and_warm_paper_grays(self) -> None:
        good_theme = """
        class AppFontSizes {
          static const double xs = 12;
          static const double sm = 14;
          static const double md = 17;
          static const double lg = 22;
        }
        class AppRadii {
          static double concentric(double outer, double gap) => outer - gap;
        }
        class AppColors {
          static const surface0 = Color(0xFFF5F4F0);
          static const surface1 = Color(0xFFFAF9F6);
          static const textPrimary = Color(0xFF242320);
          static const textSecondary = Color(0xFF5C5A54);
          static const textMuted = Color(0xFF6E6C65);
          static const accent = Color(0xFF2E5E4E);
          static List<BoxShadow> get cardShadow => const [];
        }
        """
        res = verifier.check_theme_file(good_theme)
        self.assertEqual(res["violations"], [])
        self.assertGreaterEqual(res["accent"]["white_contrast"], 7.0)

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


if __name__ == "__main__":
    unittest.main()
