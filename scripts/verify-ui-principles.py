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

RUST_TOKEN_KEY_MAP = {
    "ACCENT": "accent",
    "ON_ACCENT": "onAccent",
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

TOKEN_FONT_SIZES = {
    "xs": 12.0,
    "sm": 14.0,
    "md": 16.0,
    "lg": 22.0,
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
        r"pub\s+const\s+([A-Z0-9_]+)\s*:\s*u32\s*=\s*(0x[0-9A-Fa-f_]{8,10});",
        theme_text,
    ):
        key = RUST_TOKEN_KEY_MAP.get(m.group(1), m.group(1).lower())
        tokens[key] = m.group(2).replace("_", "")

    accent_hex = tokens.get("accent")
    accent_info: dict[str, Any] = {}
    if not accent_hex:
        violations.append("missing AppColors::ACCENT constant")
    else:
        rgb = parse_hex_color(accent_hex)
        hue, sat, val = hue_sat_val(rgb)
        foreground_hex = tokens.get("onAccent")
        if accent_hex.upper() != "0XFFC4B5FD":
            violations.append("Palette violation: ACCENT must use approved violet 0xFFC4B5FD")
        if foreground_hex is None:
            violations.append("Palette violation: missing ON_ACCENT foreground")
        else:
            foreground_contrast = round(contrast_ratio(rgb, parse_hex_color(foreground_hex)), 2)
            accent_info = {
                "hex": accent_hex, "hue_deg": round(hue, 1),
                "saturation": round(sat, 3), "value": round(val, 3),
                "foreground_contrast": foreground_contrast,
            }
            if foreground_contrast < 4.5:
                violations.append(f"Contrast violation: ON_ACCENT contrast is {foreground_contrast}:1 (< 4.5:1)")

    for key, approved in (("surface0", "0XFF1A1A1D"), ("bgPanel", "0XFF141416"), ("surface1", "0XFF202024")):
        if tokens.get(key, "").upper() != approved:
            violations.append(f"Palette violation: {key} must use approved dark surface {approved}")

    neutral_keys = ["surface0", "bgPanel", "surface1", "bgSubtle", "bgCardHover", "bgMuted",
                    "border", "borderSoft", "textPrimary", "textSecondary", "textMuted"]
    for key in neutral_keys:
        value = tokens.get(key)
        if value is None:
            violations.append(f"Palette violation: missing neutral token {key}")
            continue
        channels = parse_hex_color(value)
        if max(channels) - min(channels) > 20:
            violations.append(f"Palette violation: {key} is not a neutral surface or text color")

    for surf_key in ("surface0", "surface1", "bgPanel"):
        if surf_key not in tokens:
            continue
        for text_key in ("textPrimary", "textSecondary", "textMuted"):
            if text_key not in tokens:
                continue
            ratio = round(contrast_ratio(parse_hex_color(tokens[surf_key]), parse_hex_color(tokens[text_key])), 2)
            if ratio < 4.5:
                violations.append(f"Contrast violation: {text_key} on {surf_key} contrast is {ratio}:1 (< 4.5:1)")

    if "pub struct AppFontSizes" not in theme_text:
        violations.append("Principle 7 violation: missing AppFontSizes 4-size scale in theme file")

    if "pub const fn concentric(" not in theme_text:
        violations.append("Principle 9 violation: missing AppRadii::concentric helper in theme file")

    rust_shadow_match = re.search(
        r"pub\s+const\s+CARD_SHADOW\s*:\s*&\[u32\]\s*=\s*&(\[[^\]]*\]);",
        theme_text,
        re.DOTALL,
    )
    if rust_shadow_match:
        if rust_shadow_match.group(1).strip() != "[]":
            violations.append(
                "Principle 9 violation: AppColors::CARD_SHADOW must be empty by default so inline cards stay flat"
            )
    else:
        violations.append(
            "Principle 9 violation: AppColors::CARD_SHADOW must be empty by default so inline cards stay flat"
        )

    return {
        "accent": accent_info,
        "violations": violations,
    }


def check_theme_file(theme_text: str) -> dict[str, Any]:
    return check_palette(theme_text)


def check_ui_file(path_str: str, text: str, strict_scale: bool = True) -> dict[str, Any]:
    violations: list[str] = []
    line_count = len(text.splitlines())
    if (
        path_str.endswith(".swift") or path_str.endswith("crates/koe-host-api/src/lib.rs")
    ) and line_count > 500:
        violations.append(
            f"Architecture violation: {path_str} has {line_count} lines (max is 500 lines)"
        )

    raw_sizes = [
        float(m.group(1)) for m in re.finditer(r"\.font\(\.system\(size:\s*([0-9.]+)", text)
    ]
    swift_size_exprs = [
        m.group(1).strip() for m in re.finditer(r"\.font\(\.system\(size:\s*([^,\n)]+)", text)
    ]
    token_sizes = [
        TOKEN_FONT_SIZES[t.lower()]
        for expr in swift_size_exprs
        for t in re.findall(r"AppFontSizes(?:\.|::)([a-zA-Z0-9_]+)", expr)
        if t.lower() in TOKEN_FONT_SIZES
    ]
    dynamic_font_exprs = [
        expr
        for expr in swift_size_exprs
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
            r"\.font\(\.system\(size:\s*AppFontSizes(?:\.|::)([a-zA-Z0-9_]+)",
            text,
        )
        if m.group(1).lower() not in TOKEN_FONT_SIZES
    ]
    if unknown_tokens:
        violations.append(
            f"Principle 7 violation: {path_str} uses unknown AppFontSizes token(s): {unknown_tokens}"
        )
    distinct_sizes = sorted(set(raw_sizes + token_sizes))

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

    italics = len(re.findall(r"\.italic\(\)", text))
    if italics > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {italics} .italic() usage(s)"
        )

    uppercases = len(
        re.findall(r"\.(?:uppercased|to_uppercase|to_ascii_uppercase)\(", text)
    )
    if uppercases > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {uppercases} .uppercased() call(s)"
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
        r"0x[fF]{2}(?:b66c50|f0d9cc|a4472b|f6ebe6)\b",
        text,
        re.IGNORECASE,
    )
    if legacy_palette_hits:
        violations.append(
            f"Principle 6 violation: {path_str} uses legacy terracotta color(s): {legacy_palette_hits}"
        )

    if path_str.endswith(".swift"):
        plain_count = text.count(".buttonStyle(.plain)")
        inner_shape_before_plain = len(
            re.findall(r"\.contentShape\(Rectangle\(\)\)\s*\}\s*\.buttonStyle\(\.plain\)", text)
        )
        if plain_count > 0 and inner_shape_before_plain < plain_count:
            violations.append(
                f"Principle 10 violation: {path_str} has {plain_count} .buttonStyle(.plain) button(s) "
                f"but only {inner_shape_before_plain} wrap .contentShape(Rectangle()) inside the label closure before .buttonStyle(.plain)"
            )

        textfield_count = len(re.findall(r"\bTextField\s*\(", text))
        onsubmit_count = len(re.findall(r"\.onSubmit\b", text))
        if textfield_count > onsubmit_count:
            violations.append(
                f"UX violation: {path_str} has {textfield_count} TextField(s) but only {onsubmit_count} .onSubmit handler(s)"
            )

        if path_str.endswith("AskView.swift") and "ask.messages" not in text:
            violations.append(
                f"UX violation: {path_str} must render ask.messages so submitted prompts display sourced answers"
            )

        if path_str.endswith("KoeMacApp.swift") and "NSApp?.windows.first" in text and "isWorkspaceWindow" not in text:
            violations.append(
                f"UX violation: {path_str} must filter workspace windows via isWorkspaceWindow instead of falling back to NSApp?.windows.first (which matches NSStatusBarWindow)"
            )

        if path_str.endswith("PlayerBarView.swift") and re.search(r"durationMs\s*\+\s*1000", text):
            violations.append(
                f"UX violation: {path_str} must mark playheadMs instead of inflating durationMs + 1000 on add_slice_mark"
            )

    return {
        "file": path_str,
        "distinct_font_sizes": distinct_sizes,
        "middle_dots": middle_dots,
        "italics": italics,
        "uppercases": uppercases,
        "full_red_buttons": 0,
        "violations": violations,
    }


REQUIRED_INSTALL_PLIST_KEYS = (
    "AppIcon.icns",
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
    "--verify-self",
    "--smoke-test",
)


def check_install_script(script_text: str) -> list[str]:
    violations: list[str] = []
    for key in REQUIRED_INSTALL_PLIST_KEYS:
        if key not in script_text:
            violations.append(
                f"Packaging violation: scripts/install-macos.sh is missing required key/check '{key}'"
            )
    return violations


def analyze_repository(root: Path, mode: str) -> dict[str, Any]:
    candidates = [
        root / "crates" / "koe-client-core" / "src" / "theme.rs",
        root / "crates" / "koe-engine" / "src" / "theme.rs",
    ]
    theme_path = next((p for p in candidates if p.exists()), candidates[-1])
    theme_res = (
        check_theme_file(theme_path.read_text(encoding="utf-8"))
        if theme_path.exists()
        else {
            "accent": {},
            "violations": ["missing shared Rust theme.rs"],
        }
    )

    rel_files: list[str] = []
    if theme_path.exists():
        rel_files.append(str(theme_path.relative_to(root)))
    host_api_lib = root / "crates" / "koe-host-api" / "src" / "lib.rs"
    if host_api_lib.exists():
        rel_files.append(str(host_api_lib.relative_to(root)))
    if (root / "platforms").exists():
        rel_files.extend(
            sorted(
                str(p.relative_to(root))
                for p in (root / "platforms").rglob("*.swift")
                if ".build" not in p.parts and "DerivedData" not in p.parts
            )
        )

    file_reports: list[dict[str, Any]] = []
    all_violations: list[str] = list(theme_res["violations"])

    install_script = root / "scripts" / "install-macos.sh"
    if install_script.exists():
        all_violations.extend(check_install_script(install_script.read_text(encoding="utf-8")))

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
            "total_full_red_buttons": 0,
        },
        "violations": all_violations,
        "files": file_reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Koe UI redesign principles")
    parser.add_argument("--root", default=".", help="Repository root path")
    parser.add_argument(
        "--mode",
        choices=["audit", "all"],
        default="audit",
        help="Verification mode (`audit` exits 0 and writes baseline/report; `all` enforces 0 violations)",
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
