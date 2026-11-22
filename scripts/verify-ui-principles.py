#!/usr/bin/env python3
from __future__ import annotations

import argparse
import colorsys
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import sys
from typing import Any
import xml.parsers.expat

ALLOWED_FONT_SIZES = {12.0, 14.0, 16.0, 22.0}

TOKEN_FONT_SIZES = {
    "xs": 12.0,
    "sm": 14.0,
    "md": 16.0,
    "lg": 22.0,
}

SNAPSHOT_ALLOWED_APPLE_SHARED_FILES = {
    "HostSessionStore.swift",
    "HostSessionSlices.swift",
}

HIGH_FREQUENCY_SLICE_OWNER_BY_FILE = {
    "PlayerBarView.swift": "playback",
    "ActiveCaptureBar.swift": "activeCapture",
    "LiveCaptionBar.swift": "liveCaption",
    "LiveMinutesCoverageSlotView.swift": "liveMinutesCoverage",
}

IOS_HIGH_FREQUENCY_SLICE_OWNER_BY_FILE = {
    "IOSPlayerBarView.swift": "playback",
    "IOSActiveCaptureBar.swift": "activeCapture",
    "IOSLiveCaptionBar.swift": "liveCaption",
    "IOSLiveMinutesCoverageSlotView.swift": "liveMinutesCoverage",
}

ANDROID_HIGH_FREQUENCY_SLICE_OWNER_BY_FILE = {
    "AndroidPlayerBar.kt": "playback",
    "AndroidActiveCaptureBar.kt": "activeCapture",
    "AndroidLiveCaptionBar.kt": "liveCaption",
    "AndroidLiveMinutesCoverageSlot.kt": "liveMinutesCoverage",
}


def mask_source(
    text: str,
    *,
    strip_strings: bool = False,
    language: str = "swift",
) -> str:
    out: list[str] = []
    idx = 0
    n = len(text)
    in_line_comment = False
    block_depth = 0
    in_string = False
    in_multiline = False
    in_char = False
    raw_hashes = 0
    escaped = False

    def masked(ch: str) -> str:
        return ("\n" if ch == "\n" else " ") if strip_strings else ch

    while idx < n:
        ch = text[idx]
        if in_line_comment:
            in_line_comment = ch != "\n"
            out.append("\n" if ch == "\n" else " ")
            idx += 1
        elif block_depth > 0:
            if text.startswith("/*", idx):
                block_depth += 1
                out.append("  ")
                idx += 2
            elif text.startswith("*/", idx):
                block_depth -= 1
                out.append("  ")
                idx += 2
            else:
                out.append("\n" if ch == "\n" else " ")
                idx += 1
        elif in_char:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch in ("'", "\n"):
                in_char = False
            out.append(masked(ch))
            idx += 1
        elif in_multiline:
            if language == "kotlin":
                if text.startswith('"""', idx):
                    run_len = 0
                    while idx + run_len < n and text[idx + run_len] == '"':
                        run_len += 1
                    in_multiline = False
                    out.append(" " * run_len if strip_strings else '"' * run_len)
                    idx += run_len
                else:
                    out.append(masked(ch))
                    idx += 1
            else:
                esc_seq = "\\" + "#" * raw_hashes
                close_seq = '"""' + "#" * raw_hashes
                if escaped:
                    escaped = False
                    out.append(masked(ch))
                    idx += 1
                elif text.startswith(esc_seq, idx):
                    escaped = True
                    out.append(" " * len(esc_seq) if strip_strings else esc_seq)
                    idx += len(esc_seq)
                elif text.startswith(close_seq, idx):
                    in_multiline = False
                    raw_hashes = 0
                    out.append(" " * len(close_seq) if strip_strings else close_seq)
                    idx += len(close_seq)
                else:
                    out.append(masked(ch))
                    idx += 1
        elif in_string:
            esc_seq = "\\" + "#" * raw_hashes
            close_seq = '"' + "#" * raw_hashes
            if escaped:
                escaped = False
                out.append(masked(ch))
                idx += 1
            elif text.startswith(esc_seq, idx):
                escaped = True
                out.append(" " * len(esc_seq) if strip_strings else esc_seq)
                idx += len(esc_seq)
            elif text.startswith(close_seq, idx):
                in_string = False
                raw_hashes = 0
                out.append(" " * len(close_seq) if strip_strings else close_seq)
                idx += len(close_seq)
            else:
                out.append(masked(ch))
                idx += 1
        elif text.startswith("//", idx):
            in_line_comment = True
            out.append("  ")
            idx += 2
        elif text.startswith("/*", idx):
            block_depth = 1
            out.append("  ")
            idx += 2
        elif language == "swift" and ch == "#":
            k = 0
            while idx + k < n and text[idx + k] == "#":
                k += 1
            if text.startswith('"""', idx + k):
                in_multiline = True
                raw_hashes = k
                open_seq = text[idx : idx + k + 3]
                out.append(" " * len(open_seq) if strip_strings else open_seq)
                idx += len(open_seq)
            elif idx + k < n and text[idx + k] == '"':
                in_string = True
                raw_hashes = k
                open_seq = text[idx : idx + k + 1]
                out.append(" " * len(open_seq) if strip_strings else open_seq)
                idx += len(open_seq)
            else:
                out.append("#")
                idx += 1
        elif text.startswith('"""', idx):
            in_multiline = True
            raw_hashes = 0
            out.append("   " if strip_strings else '"""')
            idx += 3
        elif ch == '"':
            in_string = True
            raw_hashes = 0
            out.append(" " if strip_strings else ch)
            idx += 1
        elif language == "kotlin" and ch == "'":
            in_char = True
            out.append(" " if strip_strings else ch)
            idx += 1
        else:
            out.append(ch)
            idx += 1
    return "".join(out)


def find_balanced_end(code_only: str, start: int, open_ch: str, close_ch: str) -> int | None:
    depth = 0
    for idx in range(start, len(code_only)):
        ch = code_only[idx]
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return idx + 1
    return None


def extract_blocks(source: str, code_only: str, pattern: str) -> list[str]:
    blocks: list[str] = []
    for match in re.finditer(pattern, code_only):
        start = match.end() - 1
        end = find_balanced_end(code_only, start, "{", "}")
        if end is not None:
            blocks.append(source[start:end])
    return blocks


def has_unfiltered_windows_first(code_only: str) -> bool:
    n = len(code_only)
    for match in re.finditer(r"\bNSApp\??\.windows\.first\b", code_only):
        idx = match.end()
        while idx < n and code_only[idx].isspace():
            idx += 1
        if idx >= n or code_only[idx] not in "({":
            return True
        open_ch = code_only[idx]
        end = find_balanced_end(code_only, idx, open_ch, ")" if open_ch == "(" else "}")
        if end is None or "isWorkspaceWindow" not in code_only[idx:end]:
            return True
    return False


def find_foreach_offset_churn(code_only: str) -> bool:
    for match in re.finditer(r"\bForEach\s*\(", code_only):
        start = match.end() - 1
        end = find_balanced_end(code_only, start, "(", ")")
        if end is not None and re.search(r",\s*id:\s*\\\.offset\b", code_only[start:end]):
            return True
    return False


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


NEUTRAL_PALETTE_KEYS = (
    "surface0",
    "bgPanel",
    "surface1",
    "bgSubtle",
    "border",
    "textPrimary",
    "textSecondary",
    "textMuted",
)

APPROVED_LIGHT_SURFACES = (
    ("surface0", "0XFFFFFF"),
    ("bgPanel", "0XF7F7F8"),
    ("surface1", "0XFFFFFF"),
)


def _rgb_hex(hex_str: str) -> str:
    r, g, b = parse_hex_color(hex_str)
    return f"0X{r:02X}{g:02X}{b:02X}"


def _check_palette_tokens(
    tokens: dict[str, str],
    *,
    label: str = "",
    expected_accent: str | None = None,
    expected_surfaces: tuple[tuple[str, str], ...] = (),
) -> tuple[dict[str, Any], list[str]]:
    violations: list[str] = []
    suffix = f" ({label})" if label else ""
    accent_hex = tokens.get("accent")
    accent_info: dict[str, Any] = {}
    if not accent_hex:
        violations.append(f"missing {label or 'AppColors'}.accent token")
    else:
        rgb = parse_hex_color(accent_hex)
        hue, sat, val = hue_sat_val(rgb)
        foreground_hex = tokens.get("onAccent")
        if expected_accent is not None and _rgb_hex(accent_hex) != expected_accent:
            violations.append(f"Palette violation: accent{suffix} must use approved charcoal {expected_accent}")
        if foreground_hex is None:
            violations.append(f"Palette violation: missing onAccent foreground{suffix}")
        else:
            foreground_contrast = round(contrast_ratio(rgb, parse_hex_color(foreground_hex)), 2)
            accent_info = {
                "hex": accent_hex,
                "hue_deg": round(hue, 1),
                "saturation": round(sat, 3),
                "value": round(val, 3),
                "foreground_contrast": foreground_contrast,
            }
            if foreground_contrast < 4.5:
                violations.append(
                    f"Contrast violation: onAccent{suffix} contrast is {foreground_contrast}:1 (< 4.5:1)"
                )

    for key, approved in expected_surfaces:
        value = tokens.get(key)
        if value is None or _rgb_hex(value) != approved:
            violations.append(f"Palette violation: {key}{suffix} must use approved light surface {approved}")

    for key in NEUTRAL_PALETTE_KEYS:
        value = tokens.get(key)
        if value is None:
            violations.append(f"Palette violation: missing neutral token {key}{suffix}")
            continue
        channels = parse_hex_color(value)
        if max(channels) - min(channels) > 20:
            violations.append(f"Palette violation: {key}{suffix} is not a neutral surface or text color")

    for surf_key in ("surface0", "surface1", "bgPanel"):
        if surf_key not in tokens:
            continue
        for text_key in ("textPrimary", "textSecondary", "textMuted"):
            if text_key not in tokens:
                continue
            ratio = round(
                contrast_ratio(parse_hex_color(tokens[surf_key]), parse_hex_color(tokens[text_key])),
                2,
            )
            if ratio < 4.5:
                violations.append(
                    f"Contrast violation: {text_key} on {surf_key}{suffix} contrast is {ratio}:1 (< 4.5:1)"
                )

    return accent_info, violations


def check_theme_file(theme_text: str) -> dict[str, Any]:
    code_only = mask_source(theme_text, strip_strings=True, language="swift")
    tokens = {
        m.group(1): m.group(2)
        for m in re.finditer(
            r"public\s+static\s+let\s+(\w+)\s*=\s*Color\(hex:\s*(0x[0-9A-Fa-f]{6})\)",
            code_only,
        )
    }
    accent_info, violations = _check_palette_tokens(
        tokens,
        expected_accent="0X242426",
        expected_surfaces=APPROVED_LIGHT_SURFACES,
    )
    if "public enum AppFontSizes" not in code_only:
        violations.append("Principle 7 violation: missing AppFontSizes 4-size scale in theme file")
    return {"accent": accent_info, "violations": violations}


def _extract_kotlin_palette_tokens(
    code_only: str, palette_name: str, label: str
) -> tuple[dict[str, str] | None, list[str]]:
    match = re.search(
        rf"\b{re.escape(palette_name)}\s*(?::\s*[\w.]+\s*)?=\s*KoePalette\s*\(",
        code_only,
    )
    if match is None:
        return None, []
    start = match.end() - 1
    end = find_balanced_end(code_only, start, "(", ")")
    if end is None:
        return None, []
    block = code_only[start:end]
    tokens: dict[str, str] = {}
    violations: list[str] = []
    for m in re.finditer(r"(\w+)\s*=\s*Color\(\s*(0[xX][0-9A-Fa-f]+[lL]?)\s*\)", block):
        name, raw_hex = m.group(1), m.group(2)
        if not re.fullmatch(r"0[xX][fF]{2}[0-9A-Fa-f]{6}[lL]?", raw_hex):
            violations.append(
                f"Palette violation: {name} ({label}) must use opaque 8-digit ARGB 0xFFRRGGBB (got {raw_hex})"
            )
            continue
        tokens[name] = raw_hex.rstrip("lL")
    return tokens, violations


def check_android_theme_file(theme_text: str) -> dict[str, Any]:
    code_only = mask_source(theme_text, strip_strings=True, language="kotlin")
    violations: list[str] = []
    light_accent: dict[str, Any] = {}

    light_tokens, light_parse_violations = _extract_kotlin_palette_tokens(
        code_only, "LightKoePalette", "Android LightKoePalette"
    )
    violations.extend(light_parse_violations)
    if light_tokens is None:
        violations.append("Palette violation: missing LightKoePalette in Android KoeTheme.kt")
    else:
        light_accent, light_violations = _check_palette_tokens(
            light_tokens,
            label="Android LightKoePalette",
            expected_accent="0X242426",
            expected_surfaces=APPROVED_LIGHT_SURFACES,
        )
        violations.extend(light_violations)

    dark_tokens, dark_parse_violations = _extract_kotlin_palette_tokens(
        code_only, "DarkKoePalette", "Android DarkKoePalette"
    )
    violations.extend(dark_parse_violations)
    if dark_tokens is None:
        violations.append("Palette violation: missing DarkKoePalette in Android KoeTheme.kt")
    else:
        _, dark_violations = _check_palette_tokens(dark_tokens, label="Android DarkKoePalette")
        violations.extend(dark_violations)

    font_match = re.search(r"\bobject\s+KoeFontSizes\s*\{", code_only)
    if font_match is None:
        violations.append("Principle 7 violation: missing KoeFontSizes 4-size scale in Android theme file")
    else:
        end = find_balanced_end(code_only, font_match.end() - 1, "{", "}")
        block = code_only[font_match.end() - 1 : end] if end is not None else ""
        kt_sizes = {float(m.group(1)) for m in re.finditer(r"=\s*([0-9.]+)\.sp\b", block)}
        if kt_sizes != ALLOWED_FONT_SIZES:
            violations.append(
                f"Principle 7 violation: KoeFontSizes defines {sorted(kt_sizes)} (expected {sorted(ALLOWED_FONT_SIZES)})"
            )

    return {
        "accent": light_accent,
        "violations": violations,
    }


def _check_scoped_observation(
    path_str: str,
    source: str,
    *,
    slice_kind: str,
    allowed_prop: str | None = None,
    check_snapshot: bool = True,
    check_high_frequency: bool = True,
) -> list[str]:
    violations: list[str] = []
    if check_snapshot and re.search(r"\bstore\??\.snapshot\b", source):
        violations.append(
            f"Observation violation: {path_str} reads store.snapshot directly; use a scoped {slice_kind} slice instead"
        )
    if check_high_frequency:
        hf_props = sorted(
            set(
                re.findall(
                    r"\bstore\??\.(playback|activeCapture|liveCaption|liveMinutesCoverage)\b",
                    source,
                )
            )
        )
        disallowed = [f"store.{p}" for p in hf_props if p != allowed_prop]
        if disallowed:
            violations.append(
                f"Observation violation: {path_str} reads 4 Hz high-frequency slice(s) {disallowed} outside designated leaf views"
            )
    return violations


def check_ui_file(path_str: str, text: str, strict_scale: bool = True) -> dict[str, Any]:
    violations: list[str] = []
    line_count = len(text.splitlines())
    if (
        path_str.endswith(".swift")
        or path_str.endswith(".kt")
        or path_str.endswith("crates/koe-host-api/src/lib.rs")
    ) and line_count > 500:
        violations.append(
            f"Architecture violation: {path_str} has {line_count} lines (max is 500 lines)"
        )

    language = "kotlin" if path_str.endswith(".kt") else ("swift" if path_str.endswith(".swift") else "rust")
    comment_stripped = mask_source(text, strip_strings=False, language=language)
    code_only = mask_source(text, strip_strings=True, language=language)

    raw_sizes = [
        float(m.group(1))
        for m in re.finditer(r"\.font\(\.system\(size:\s*([0-9.]+)", comment_stripped)
    ]
    swift_size_exprs = [
        m.group(1).strip()
        for m in re.finditer(r"\.font\(\.system\(size:\s*([^,\n)]+)", comment_stripped)
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
            comment_stripped,
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

    middle_dots = comment_stripped.count("·")
    if middle_dots > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {middle_dots} middle dot '·' connector(s)"
        )

    italics = len(re.findall(r"\.italic\(\)", comment_stripped))
    if italics > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {italics} .italic() usage(s)"
        )

    uppercases = len(
        re.findall(
            r"\.(?:uppercased|uppercase|to_uppercase|to_ascii_uppercase)\(",
            comment_stripped,
        )
    )
    if uppercases > 0:
        violations.append(
            f"Principle 8 violation: {path_str} contains {uppercases} .uppercased()/.uppercase() call(s)"
        )

    pushy_verbs = re.findall(
        r"立即(?:购买|体验|开启|升级|绑定|转写|同步|隐藏|执行|前往)",
        comment_stripped,
    )
    if pushy_verbs:
        violations.append(
            f"Principle 8 violation: {path_str} contains pushy marketing verb(s): {pushy_verbs}"
        )

    if "移到回收站？" in comment_stripped:
        violations.append(
            f"Principle 5 violation: {path_str} prompts confirmation dialog '移到回收站？' for a reversible 30-day trash operation"
        )

    legacy_palette_hits = re.findall(
        r"0x[fF]{2}(?:b66c50|f0d9cc|a4472b|f6ebe6)\b",
        comment_stripped,
        re.IGNORECASE,
    )
    if legacy_palette_hits:
        violations.append(
            f"Principle 6 violation: {path_str} uses legacy terracotta color(s): {legacy_palette_hits}"
        )

    if path_str.endswith(".swift"):
        plain_count = comment_stripped.count(".buttonStyle(.plain)")
        inner_shape_before_plain = len(
            re.findall(
                r"\.contentShape\(Rectangle\(\)\)\s*\}\s*\.buttonStyle\(\.plain\)",
                comment_stripped,
            )
        )
        if plain_count > 0 and inner_shape_before_plain < plain_count:
            violations.append(
                f"Principle 10 violation: {path_str} has {plain_count} .buttonStyle(.plain) button(s) "
                f"but only {inner_shape_before_plain} wrap .contentShape(Rectangle()) inside the label closure before .buttonStyle(.plain)"
            )

        textfield_count = len(re.findall(r"\bTextField\s*\(", comment_stripped))
        onsubmit_count = len(re.findall(r"\.onSubmit\b", comment_stripped))
        if textfield_count > onsubmit_count:
            violations.append(
                f"UX violation: {path_str} has {textfield_count} TextField(s) but only {onsubmit_count} .onSubmit handler(s)"
            )

        if path_str.endswith("AskView.swift") and "ask.messages" not in comment_stripped:
            violations.append(
                f"UX violation: {path_str} must render ask.messages so submitted prompts display sourced answers"
            )

        if (
            Path(path_str.replace("\\", "/")).name in ("KoeMacApp.swift", "KoeWindowPresenter.swift")
            and has_unfiltered_windows_first(code_only)
        ):
            violations.append(
                f"UX violation: {path_str} must filter workspace windows via isWorkspaceWindow instead of falling back to NSApp?.windows.first (which matches NSStatusBarWindow)"
            )

        if path_str.endswith("PlayerBarView.swift") and re.search(
            r"durationMs\s*\+\s*1000", comment_stripped
        ):
            violations.append(
                f"UX violation: {path_str} must mark playheadMs instead of inflating durationMs + 1000 on add_slice_mark"
            )

        if find_foreach_offset_churn(code_only):
            violations.append(
                f"Observation violation: {path_str} uses ForEach(..., id: \\.offset); use stable item identity instead"
            )

        norm_path = "/" + path_str.replace("\\", "/").lstrip("/")
        filename = Path(norm_path).name
        if "/platforms/apple-shared/Sources/KoeAppleCore/" in norm_path:
            forbidden_imports = sorted(
                set(
                    re.findall(
                        r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(AppKit|SwiftUI|UIKit)\b",
                        code_only,
                    )
                )
            )
            if forbidden_imports:
                violations.append(
                    f"Architecture violation: {path_str} imports forbidden UI framework(s) {forbidden_imports} inside platform-neutral KoeAppleCore"
                )
            if filename not in SNAPSHOT_ALLOWED_APPLE_SHARED_FILES:
                violations.extend(
                    _check_scoped_observation(path_str, comment_stripped, slice_kind="@Observable")
                )
        elif "/platforms/apple-shared/Sources/KoeAppleShared/" in norm_path:
            if filename not in SNAPSHOT_ALLOWED_APPLE_SHARED_FILES:
                violations.extend(
                    _check_scoped_observation(
                        path_str,
                        comment_stripped,
                        slice_kind="@Observable",
                        allowed_prop=HIGH_FREQUENCY_SLICE_OWNER_BY_FILE.get(filename),
                    )
                )
        elif "/platforms/macos/Sources/Koe/" in norm_path:
            swiftui_blocks = "\n".join(
                extract_blocks(comment_stripped, code_only, r"\bstruct\s+\w+\s*:[^{]*\b(?:View|App)\b[^{]*\{")
            )
            snapshot_guarded_blocks = swiftui_blocks
            if filename in ("KoeMacApp.swift", "KoeWindowPresenter.swift"):
                delegate_blocks = "\n".join(
                    extract_blocks(
                        comment_stripped,
                        code_only,
                        r"\b(?:(?:class|extension)\s+KoeAppDelegate|(?:enum|extension)\s+KoeWindowPresenter)\b[^{]*\{",
                    )
                )
                snapshot_guarded_blocks = "\n".join(b for b in (swiftui_blocks, delegate_blocks) if b)
            if snapshot_guarded_blocks:
                violations.extend(
                    _check_scoped_observation(
                        path_str,
                        snapshot_guarded_blocks,
                        slice_kind="@Observable",
                        check_high_frequency=False,
                    )
                )
            if swiftui_blocks:
                violations.extend(
                    _check_scoped_observation(
                        path_str,
                        swiftui_blocks,
                        slice_kind="@Observable",
                        check_snapshot=False,
                    )
                )
        elif "/platforms/ios/App/Sources/" in norm_path:
            swiftui_blocks = "\n".join(
                extract_blocks(comment_stripped, code_only, r"\bstruct\s+\w+\s*:[^{]*\b(?:View|App)\b[^{]*\{")
            )
            if swiftui_blocks:
                violations.extend(
                    _check_scoped_observation(
                        path_str,
                        swiftui_blocks,
                        slice_kind="@Observable",
                        allowed_prop=IOS_HIGH_FREQUENCY_SLICE_OWNER_BY_FILE.get(filename),
                    )
                )
    elif path_str.endswith(".kt"):
        norm_path = "/" + path_str.replace("\\", "/").lstrip("/")
        if "/com/semanticcraft/koe/core/" in norm_path:
            forbidden_imports = sorted(
                set(
                    re.findall(
                        r"\bimport\s+(androidx\.compose|android\.widget|android\.view)\b",
                        code_only,
                    )
                )
            )
            if forbidden_imports:
                violations.append(
                    f"Architecture violation: {path_str} imports forbidden UI framework(s) {forbidden_imports} inside platform-neutral com.semanticcraft.koe.core"
                )
        elif "/com/semanticcraft/koe/ui/" in norm_path:
            violations.extend(
                _check_scoped_observation(
                    path_str,
                    comment_stripped,
                    slice_kind="StateFlow",
                    allowed_prop=ANDROID_HIGH_FREQUENCY_SLICE_OWNER_BY_FILE.get(Path(norm_path).name),
                )
            )

    return {
        "file": path_str,
        "distinct_font_sizes": distinct_sizes,
        "middle_dots": middle_dots,
        "italics": italics,
        "uppercases": uppercases,
        "violations": violations,
    }


REQUIRED_INSTALL_PLIST_KEYS = (
    "AppIcon.icns",
    "CFBundleIconFile",
    "NSBluetoothAlwaysUsageDescription",
    "NSBluetoothPeripheralUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSAudioCaptureUsageDescription",
    "NSSpeechRecognitionUsageDescription",
    "--verify-self",
    "--smoke-test",
)


def check_install_script(script_text: str) -> list[str]:
    violations: list[str] = []
    active_lines: list[str] = []
    for line in script_text.splitlines():
        if re.match(r"^\s*#", line):
            continue
        if not line.lstrip().startswith("<"):
            line = re.sub(r"\s+#.*$", "", line)
        active_lines.append(line)
    active_text = "\n".join(active_lines)

    for key in REQUIRED_INSTALL_PLIST_KEYS:
        if key not in active_text:
            violations.append(
                f"Packaging violation: scripts/install-macos.sh is missing required key/check '{key}'"
            )
    if "CFBundleIconName" in active_text and "Assets.car" not in active_text:
        violations.append(
            "Packaging violation: scripts/install-macos.sh sets CFBundleIconName without bundling Assets.car"
        )
    if re.search(
        r"Contents/Resources[^\n]*AppIcon\.png|AppIcon\.png[^\n]*Contents/Resources",
        active_text,
    ):
        violations.append(
            "Packaging violation: scripts/install-macos.sh must not copy unpadded AppIcon.png into Contents/Resources"
        )
    if "lsregister" not in active_text or not re.search(
        r'(?:lsregister|\$\{?LSREGISTER\}?)"?(?:\s+-[A-Za-z]+)*\s+-f(?:\s+-[A-Za-z]+)*\s+\S+',
        active_text,
    ):
        violations.append(
            "Packaging violation: scripts/install-macos.sh must register the installed bundle with lsregister -f"
        )

    plist_match = re.search(r"<plist\b[\s\S]*?</plist>", active_text)
    if plist_match is not None:
        raw_plist = plist_match.group(0)
        xml_doc = (
            raw_plist
            if raw_plist.lstrip().startswith("<?xml")
            else '<?xml version="1.0" encoding="UTF-8"?>\n' + raw_plist
        )
        try:
            plist_data = plistlib.loads(xml_doc.encode("utf-8"))
        except (plistlib.InvalidFileException, xml.parsers.expat.ExpatError, ValueError, TypeError) as exc:
            violations.append(
                f"Packaging violation: scripts/install-macos.sh contains invalid Info.plist XML ({exc})"
            )
            plist_data = None
        if isinstance(plist_data, dict):
            if plist_data.get("CFBundleIconFile") != "AppIcon":
                violations.append(
                    "Packaging violation: scripts/install-macos.sh Info.plist must set CFBundleIconFile to AppIcon"
                )
            if "CFBundleIconName" in plist_data and "Assets.car" not in active_text:
                msg = "Packaging violation: scripts/install-macos.sh sets CFBundleIconName without bundling Assets.car"
                if msg not in violations:
                    violations.append(msg)
            for key in REQUIRED_INSTALL_PLIST_KEYS:
                if key.startswith("NS"):
                    val = plist_data.get(key)
                    if not isinstance(val, str) or not val.strip():
                        violations.append(
                            f"Packaging violation: scripts/install-macos.sh Info.plist must set non-empty '{key}'"
                        )
    return violations


def analyze_repository(root: Path, mode: str) -> dict[str, Any]:
    theme_path = root / "platforms" / "apple-shared" / "Sources" / "KoeAppleShared" / "DesignKit.swift"
    theme_res = (
        check_theme_file(theme_path.read_text(encoding="utf-8"))
        if theme_path.exists()
        else {
            "accent": {},
            "violations": ["missing shared Swift DesignKit.swift"],
        }
    )

    android_theme_path = (
        root
        / "platforms"
        / "android"
        / "gradle-app"
        / "app"
        / "src"
        / "main"
        / "java"
        / "com"
        / "semanticcraft"
        / "koe"
        / "ui"
        / "theme"
        / "KoeTheme.kt"
    )
    android_gradle_path = root / "platforms" / "android" / "gradle-app" / "app" / "build.gradle.kts"
    if android_theme_path.exists():
        android_theme_res = check_android_theme_file(android_theme_path.read_text(encoding="utf-8"))
    elif android_gradle_path.exists():
        android_theme_res = {"accent": {}, "violations": ["missing Android KoeTheme.kt"]}
    else:
        android_theme_res = {"accent": {}, "violations": []}

    rel_files: list[str] = []
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
    android_kotlin_root = (
        root / "platforms" / "android" / "gradle-app" / "app" / "src" / "main" / "java"
    )
    if android_kotlin_root.exists():
        rel_files.extend(
            sorted(
                str(p.relative_to(root))
                for p in android_kotlin_root.rglob("*.kt")
                if "build" not in p.parts and ".gradle" not in p.parts
            )
        )

    file_reports: list[dict[str, Any]] = []
    all_violations: list[str] = list(theme_res["violations"]) + list(android_theme_res["violations"])

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
        "android_theme": android_theme_res,
        "summary": {
            "total_violations": len(all_violations),
            "total_middle_dots": total_middle_dots,
            "files_over_4_font_sizes": files_over_4_sizes,
            "total_uppercases": sum(r["uppercases"] for r in file_reports),
            "total_italics": sum(r["italics"] for r in file_reports),
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
