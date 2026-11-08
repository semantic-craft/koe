#!/usr/bin/env python3
from __future__ import annotations

import argparse
import colorsys
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
from typing import Any

ALLOWED_FONT_SIZES = {12.0, 14.0, 16.0, 22.0}

REQUIRED_EDITORIAL_FILLS = (
    "0xFFFCEEE5",
    "0xFFDFEFCD",
    "0xFFFAECEF",
    "0xFFFAF7EB",
    "0xFFECF6FA",
    "0xFFECEFFA",
)

SLICE_SCOPES = {
    "slice-b": [
        "desktop/app/src/theme.rs",
        "desktop/app/src/main.rs",
    ],
    "slice-c": [
        "desktop/app/src/theme.rs",
        "desktop/app/src/main.rs",
    ],
    "slice-d": [
        "desktop/app/src/theme.rs",
        "desktop/app/src/main.rs",
    ],
    "slice-r": [
        "desktop/app/src/theme.rs",
        "desktop/app/src/main.rs",
    ],
}

RUST_TOKEN_KEY_MAP = {
    "ACCENT": "accent",
    "ORANGE_BRAND": "orangeBrand",
    "ORANGE_ACTION": "orangeAction",
    "ORANGE_DEEP": "orangeDeep",
    "ORANGE_TINT": "orangeTint",
    "ORANGE_BORDER": "orangeBorder",
    "SURFACE_0": "surface0",
    "SURFACE_1": "surface1",
    "BG_CARD": "bgCard",
    "BG_CARD_HOVER": "bgCardHover",
    "BG_PANEL": "bgPanel",
    "BG_SUBTLE": "bgSubtle",
    "BG_MUTED": "bgMuted",
    "BORDER_SOFT": "borderSoft",
    "BORDER": "border",
    "BORDER_STRONG": "borderStrong",
    "BORDER_SELECTED": "borderSelected",
    "TEXT_PRIMARY": "textPrimary",
    "TEXT_SECONDARY": "textSecondary",
    "TEXT_MUTED": "textMuted",
}


def parse_hex_color(hex_str: str) -> tuple[int, int, int]:
    cleaned = hex_str.strip().upper()
    if cleaned.startswith("0X"):
        cleaned = cleaned[2:]
    if len(cleaned) == 8:
        cleaned = cleaned[2:]
    return int(cleaned[0:2], 16), int(cleaned[2:4], 16), int(cleaned[4:6], 16)


def relative_luminance(rgb: tuple[int, int, int]) -> float:
    def channel(c: int) -> float:
        s = c / 255.0
        return s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4

    r, g, b = rgb
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast_ratio(c1: tuple[int, int, int], c2: tuple[int, int, int]) -> float:
    l1 = relative_luminance(c1)
    l2 = relative_luminance(c2)
    lighter, darker = max(l1, l2), min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


def hue_sat_val(rgb: tuple[int, int, int]) -> tuple[float, float, float]:
    r, g, b = (c / 255.0 for c in rgb)
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    return h * 360.0, s, v


def check_palette(theme_text: str) -> dict[str, Any]:
    violations: list[str] = []
    tokens: dict[str, str] = {}
    for m in re.finditer(
        r"static\s+const\s+(?:Color\s+)?([a-zA-Z0-9_]+)\s*=\s*Color\((0x[0-9A-Fa-f]{8})\);",
        theme_text,
    ):
        tokens[m.group(1)] = m.group(2)
    for m in re.finditer(
        r"pub\s+const\s+([A-Z0-9_]+)\s*:\s*u32\s*=\s*(0x[0-9A-Fa-f_]{8,10});",
        theme_text,
    ):
        key = RUST_TOKEN_KEY_MAP.get(m.group(1), m.group(1).lower())
        tokens[key] = m.group(2).replace("_", "")

    if re.search(r"0x[fF]{2}[aA]4472[bB]\b", theme_text):
        violations.append("Principle 6 violation: theme contains legacy terracotta 0xFFA4472B")
    if re.search(r"0x[fF]{2}0066[cC]{2}\b", theme_text):
        violations.append("Principle 6 violation: theme contains legacy bright blue 0xFF0066CC")

    accent_hex = tokens.get("accent")
    accent_info: dict[str, Any] = {}
    if not accent_hex:
        violations.append("missing AppColors.accent constant")
    else:
        rgb = parse_hex_color(accent_hex)
        hue, sat, val = hue_sat_val(rgb)
        white_contrast = round(contrast_ratio(rgb, (255, 255, 255)), 2)
        accent_info = {
            "hex": accent_hex,
            "hue_deg": round(hue, 1),
            "saturation": round(sat, 3),
            "value": round(val, 3),
            "white_contrast": white_contrast,
        }
        if accent_hex.upper() == "0XFFA4472B":
            violations.append(
                f"Principle 6 violation: AppColors.accent ({accent_hex}) is legacy terracotta"
            )
        if 200.0 <= hue <= 230.0 and sat > 0.60:
            violations.append(
                f"Principle 6 violation: AppColors.accent ({accent_hex}, hue={hue:.1f} deg, sat={sat:.2f}) is legacy bright blue"
            )
        if not (10.0 <= hue <= 28.0 and sat >= 0.70):
            violations.append(
                f"Principle 6 violation: AppColors.accent ({accent_hex}, hue={hue:.1f} deg, sat={sat:.2f}) is not Vecta Illinois Orange"
            )
        if white_contrast < 4.25:
            violations.append(
                f"Principle 7 violation: white on AppColors.accent ({accent_hex}) contrast is {white_contrast}:1 (< 4.25:1 action orange floor)"
            )

    brand_hex = tokens.get("orangeBrand")
    if not brand_hex:
        violations.append("Principle 6 violation: missing AppColors::ORANGE_BRAND constant")
    else:
        b_rgb = parse_hex_color(brand_hex)
        b_hue, b_sat, _ = hue_sat_val(b_rgb)
        if brand_hex.upper() != "0XFFFF5F05" or not (15.0 <= b_hue <= 28.0 and b_sat >= 0.85):
            violations.append(
                f"Principle 6 violation: ORANGE_BRAND ({brand_hex}) must be Illinois Orange 0xFFFF5F05"
            )

    if tokens.get("surface0", "").upper() != "0XFFFAFAFA":
        violations.append(
            f"Principle 6 violation: SURFACE_0 ({tokens.get('surface0')}) must be 0xFFFAFAFA"
        )
    if tokens.get("bgPanel", "").upper() != "0XFFF0F0F2":
        violations.append(
            f"Principle 6 violation: BG_PANEL ({tokens.get('bgPanel')}) must be 0xFFF0F0F2"
        )

    neutral_keys = [
        "surface0",
        "bgPanel",
        "surface1",
        "bgSubtle",
        "bgCardHover",
        "bgMuted",
        "border",
        "borderSoft",
        "textPrimary",
        "textSecondary",
        "textMuted",
    ]
    for key in neutral_keys:
        hx = tokens.get(key)
        if not hx:
            violations.append(f"Principle 6 violation: missing neutral token {key}")
            continue
        r, g, b = parse_hex_color(hx)
        if abs(r - b) > 12 or abs(r - g) > 12:
            violations.append(
                f"Principle 6 violation: {key} ({hx}) is not a Vecta neutral gray (R={r}, G={g}, B={b})"
            )

    for surf_key in ("surface0", "surface1"):
        if surf_key not in tokens:
            continue
        s_rgb = parse_hex_color(tokens[surf_key])
        for txt_key in ("textPrimary", "textSecondary", "textMuted"):
            if txt_key not in tokens:
                continue
            t_rgb = parse_hex_color(tokens[txt_key])
            cr = round(contrast_ratio(s_rgb, t_rgb), 2)
            if cr < 4.5:
                violations.append(
                    f"Principle 7 violation: {txt_key} on {surf_key} contrast is {cr}:1 (< 4.5:1)"
                )

    if "AIVisualEditorialPalette" not in theme_text:
        violations.append("Principle 6 violation: missing AIVisualEditorialPalette in theme file")
    else:
        text_primary_rgb = parse_hex_color(tokens.get("textPrimary", "0xFF171719"))
        upper_theme = theme_text.upper()
        for fill_hex in REQUIRED_EDITORIAL_FILLS:
            if fill_hex.upper() not in upper_theme:
                violations.append(
                    f"Principle 6 violation: AIVisualEditorialPalette missing soft role fill {fill_hex}"
                )
            else:
                fill_rgb = parse_hex_color(fill_hex)
                cr = round(contrast_ratio(fill_rgb, text_primary_rgb), 2)
                if cr < 7.0:
                    violations.append(
                        f"Principle 7 violation: editorial fill {fill_hex} vs TEXT_PRIMARY contrast is {cr}:1 (< 7.0:1)"
                    )

    if "class AppFontSizes" not in theme_text and "pub struct AppFontSizes" not in theme_text:
        violations.append("Principle 7 violation: missing AppFontSizes 4-size scale in theme file")

    if (
        "static double concentric(" not in theme_text
        and "pub const fn concentric(" not in theme_text
    ):
        violations.append("Principle 9 violation: missing AppRadii.concentric helper in theme file")

    card_shadow_match = re.search(
        r"static\s+(?:const\s+)?List<BoxShadow>\s+(?:get\s+)?cardShadow\s*(?:=>|=)\s*(?:const\s+)?(\[[^\]]*\]);",
        theme_text,
        re.DOTALL,
    )
    rust_shadow_match = re.search(
        r"pub\s+const\s+CARD_SHADOW\s*:\s*&\[u32\]\s*=\s*&(\[[^\]]*\]);",
        theme_text,
        re.DOTALL,
    )
    if card_shadow_match:
        if "BoxShadow(" in card_shadow_match.group(1):
            violations.append(
                "Principle 9 violation: AppColors.cardShadow must be empty by default so inline cards stay flat"
            )
    elif rust_shadow_match:
        if rust_shadow_match.group(1).strip() != "[]":
            violations.append(
                "Principle 9 violation: AppColors::CARD_SHADOW must be empty by default so inline cards stay flat"
            )
    else:
        violations.append(
            "Principle 9 violation: AppColors.cardShadow must be empty by default so inline cards stay flat"
        )

    return {
        "accent": accent_info,
        "violations": violations,
    }


def check_theme_file(theme_text: str) -> dict[str, Any]:
    return check_palette(theme_text)


TOKEN_FONT_SIZES = {
    "xs": 12.0,
    "sm": 14.0,
    "md": 16.0,
    "lg": 22.0,
}

TEXT_THEME_SLOT_SIZES = {
    "displayLarge": 22.0,
    "displayMedium": 22.0,
    "displaySmall": 22.0,
    "headlineLarge": 22.0,
    "headlineMedium": 22.0,
    "headlineSmall": 16.0,
    "titleLarge": 22.0,
    "titleMedium": 16.0,
    "titleSmall": 14.0,
    "bodyLarge": 14.0,
    "bodyMedium": 14.0,
    "bodySmall": 12.0,
    "labelLarge": 14.0,
    "labelMedium": 12.0,
    "labelSmall": 12.0,
}


def check_ui_file(path_str: str, text: str, strict_scale: bool = True) -> dict[str, Any]:
    violations: list[str] = []
    raw_sizes = [float(m.group(1)) for m in re.finditer(r"fontSize:\s*([0-9.]+)", text)]
    raw_sizes.extend(
        float(m.group(1)) for m in re.finditer(r"\.text_size\(px\(([0-9.]+)\)\)", text)
    )
    font_size_exprs = [
        m.group(1).strip() for m in re.finditer(r"fontSize:\s*([^,\n)]+)", text)
    ]
    gpui_size_exprs = [
        m.group(1).strip() for m in re.finditer(r"\.text_size\(px\(([^)]+)\)\)", text)
    ]
    token_sizes = [
        TOKEN_FONT_SIZES[t.lower()]
        for expr in (font_size_exprs + gpui_size_exprs)
        for t in re.findall(r"AppFontSizes(?:\.|::)([a-zA-Z0-9_]+)", expr)
        if t.lower() in TOKEN_FONT_SIZES
    ]
    slot_sizes = [
        TEXT_THEME_SLOT_SIZES[m.group(1)]
        for m in re.finditer(r"textTheme\.([a-zA-Z0-9_]+)\b", text)
        if m.group(1) in TEXT_THEME_SLOT_SIZES
    ]
    dynamic_font_exprs = [
        expr
        for expr in (font_size_exprs + gpui_size_exprs)
        if not re.fullmatch(
            r"(?:[0-9.]+|AppFontSizes(?:\.|::)[a-zA-Z0-9_]+|[a-zA-Z_][a-zA-Z0-9_]*\s*\?\s*AppFontSizes\.[a-zA-Z0-9_]+\s*:\s*AppFontSizes\.[a-zA-Z0-9_]+)",
            expr,
        )
    ]
    if dynamic_font_exprs:
        violations.append(
            f"Principle 7 violation: {path_str} uses dynamic off-scale fontSize expression(s): {dynamic_font_exprs}"
        )
    unknown_tokens = [
        m.group(1)
        for m in re.finditer(
            r"(?:fontSize:\s*|\.text_size\(px\()AppFontSizes(?:\.|::)([a-zA-Z0-9_]+)",
            text,
        )
        if m.group(1).lower() not in TOKEN_FONT_SIZES
    ]
    if unknown_tokens:
        violations.append(
            f"Principle 7 violation: {path_str} uses unknown AppFontSizes token(s): {unknown_tokens}"
        )
    distinct_sizes = sorted(set(raw_sizes + token_sizes + slot_sizes))

    if len(distinct_sizes) > 4:
        violations.append(
            f"Principle 7 violation: {path_str} uses {len(distinct_sizes)} distinct font sizes ({distinct_sizes}), max is 4"
        )

    if strict_scale:
        off_scale = [s for s in distinct_sizes if s not in ALLOWED_FONT_SIZES]
        if off_scale:
            violations.append(
                f"Principle 7 violation: {path_str} uses off-scale font sizes {off_scale} (allowed: {sorted(ALLOWED_FONT_SIZES)})"
            )

    middle_dots = text.count("·")
    if middle_dots > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {middle_dots} middle dot '·' connector(s)"
        )

    italics = len(re.findall(r"FontStyle\.italic", text))
    if italics > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {italics} FontStyle.italic usage(s)"
        )

    uppercases = len(
        re.findall(r"\.(?:toUpperCase|to_uppercase|to_ascii_uppercase)\(", text)
    )
    if uppercases > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {uppercases} .toUpperCase() call(s)"
        )

    pushy_verbs = re.findall(r"立即(?:购买|体验|开启|升级|绑定|转写|同步|隐藏|执行|前往)", text)
    if pushy_verbs:
        violations.append(
            f"Principle 8 violation: {path_str} contains pushy marketing verb(s): {pushy_verbs}"
        )

    if "移到回收站？" in text:
        violations.append(
            f"Principle 5 violation: {path_str} prompts confirmation dialog '移到回收站？' for a reversible 30-day trash operation"
        )

    legacy_palette_hits = re.findall(
        r"0x[fF]{2}(?:b66c50|f0d9cc|a4472b|f6ebe6)\b|Colors\.(?:green|red)\b",
        text,
    )
    if legacy_palette_hits:
        violations.append(
            f"Principle 6 violation: {path_str} uses legacy terracotta or unstyled Material color(s): {legacy_palette_hits}"
        )

    full_red_buttons = len(
        re.findall(
            r"FilledButton(?:\.icon)?\([^;]*?backgroundColor:\s*(?:AppColors|tokens)\.coral",
            text,
            re.DOTALL,
        )
    )
    if full_red_buttons > 0:
        violations.append(
            f"Principle 5 violation: {path_str} uses {full_red_buttons} full-red destructive FilledButton(s)"
        )

    if path_str.endswith("home_screen.dart"):
        if "点「扫描」查找安克录音豆" in text or "tooltip: '扫描'" in text:
            violations.append(
                "Principle 1/3/8 violation: home_screen.dart uses radar icon + '扫描' instead of unified '连接录音豆' button"
            )

    if path_str.endswith("widgets/widgets.dart"):
        if re.search(r"class\s+BatteryRing[\s\S]*?tokens\.amber[\s\S]*?tokens\.coral", text):
            violations.append(
                "Principle 6 violation: BatteryRing mixes amber and coral multi-accents on the same widget"
            )

    return {
        "file": path_str,
        "distinct_font_sizes": distinct_sizes,
        "middle_dots": middle_dots,
        "italics": italics,
        "uppercases": uppercases,
        "full_red_buttons": full_red_buttons,
        "violations": violations,
    }


def analyze_repository(root: Path, mode: str) -> dict[str, Any]:
    rust_theme = root / "desktop" / "app" / "src" / "theme.rs"
    dart_theme = root / "lib" / "theme" / "app_theme.dart"
    theme_path = rust_theme if rust_theme.exists() else dart_theme
    theme_res = check_theme_file(theme_path.read_text(encoding="utf-8")) if theme_path.exists() else {
        "accent": {},
        "violations": ["missing desktop/app/src/theme.rs"],
    }

    if mode in SLICE_SCOPES:
        rel_files = SLICE_SCOPES[mode]
    elif (root / "desktop" / "app" / "src").exists():
        rel_files = sorted(
            str(p.relative_to(root))
            for p in (root / "desktop" / "app" / "src").rglob("*.rs")
        )
    else:
        rel_files = sorted(
            str(p.relative_to(root))
            for p in list((root / "lib" / "theme").rglob("*.dart"))
            + list((root / "lib" / "ui").rglob("*.dart"))
        )

    file_reports: list[dict[str, Any]] = []
    all_violations: list[str] = list(theme_res["violations"])

    for rel in rel_files:
        fp = root / rel
        if not fp.exists():
            all_violations.append(f"missing target file: {rel}")
            continue
        rep = check_ui_file(rel, fp.read_text(encoding="utf-8"), strict_scale=True)
        file_reports.append(rep)
        all_violations.extend(rep["violations"])

    total_middle_dots = sum(r["middle_dots"] for r in file_reports)
    files_over_4_sizes = sum(1 for r in file_reports if len(r["distinct_font_sizes"]) > 4)

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": mode,
        "checked_files_count": len(file_reports),
        "theme": theme_res,
        "summary": {
            "total_violations": len(all_violations),
            "total_middle_dots": total_middle_dots,
            "files_over_4_font_sizes": files_over_4_sizes,
            "total_uppercases": sum(r["uppercases"] for r in file_reports),
            "total_italics": sum(r["italics"] for r in file_reports),
            "total_full_red_buttons": sum(r["full_red_buttons"] for r in file_reports),
        },
        "violations": all_violations,
        "files": file_reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Koe UI redesign principles")
    parser.add_argument("--root", default=".", help="Repository root path")
    parser.add_argument(
        "--mode",
        choices=["audit", "slice-b", "slice-c", "slice-d", "slice-r", "all"],
        default="audit",
        help="Verification mode (`audit` exits 0 and writes baseline/report; slice modes enforce 0 violations)",
    )
    parser.add_argument("--output", help="Optional JSON receipt output path")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    report = analyze_repository(root, args.mode)

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(
        f"[verify-ui-principles] mode={args.mode} files={report['checked_files_count']} "
        f"violations={report['summary']['total_violations']} "
        f"middle_dots={report['summary']['total_middle_dots']} "
        f"files_over_4_sizes={report['summary']['files_over_4_font_sizes']}"
    )
    if args.mode != "audit" and report["violations"]:
        for v in report["violations"]:
            print(f"  - {v}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
