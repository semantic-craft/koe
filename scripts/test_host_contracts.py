#!/usr/bin/env python3
import ast
from pathlib import Path
import re
import tempfile
from typing import NamedTuple
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
RUST_COMMAND_RS = REPO_ROOT / 'crates/koe-runtime/src/command.rs'
RUST_HOST_API_DIR = REPO_ROOT / 'crates/koe-host-api/src'
C_HOST_API_HEADER = REPO_ROOT / 'platforms/apple-shared/Sources/CKoeHostApi/include/koe_host_api.h'
RUST_RUNTIME_LIB_RS = REPO_ROOT / 'crates/koe-runtime/src/lib.rs'
RUST_LOCAL_BRIDGE_RS = REPO_ROOT / 'crates/koe-host-api/src/local_bridge.rs'
ANDROID_CLIENT_JNI_CPP = REPO_ROOT / 'platforms/android/native/client_jni.cpp'
SWIFT_HOST_COMMAND = REPO_ROOT / 'platforms/apple-shared/Sources/KoeAppleCore/HostCommand.swift'
SWIFT_ADAPTER_EVENT = REPO_ROOT / 'platforms/apple-shared/Sources/KoeAppleCore/HostAdapterEvent.swift'
KOTLIN_HOST_COMMAND = (
    REPO_ROOT
    / 'platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/HostCommandModels.kt'
)
KOTLIN_ADAPTER_EVENT = (
    REPO_ROOT
    / 'platforms/android/gradle-app/app/src/main/java/com/semanticcraft/koe/core/HostAdapterEventModels.kt'
)
CLIENT_STATUS_CHECK_DIRS = (
    REPO_ROOT / 'platforms/apple-shared/Sources/KoeAppleCore',
    REPO_ROOT / 'platforms/apple-shared/Sources/KoeMacUI',
    REPO_ROOT / 'platforms/macos/Sources/Koe',
    REPO_ROOT / 'platforms/ios/App/Sources',
    REPO_ROOT / 'platforms/android/gradle-app/app/src/main/java',
)
FORBIDDEN_RECORD_STATUS_LITERALS = ('转写中', '整理中', '等待转写')
EXPECTED_MAX_COMMAND_JSON_BYTES = 2 * 1024 * 1024

KOTLIN_MODIFIERS = frozenset(
    {
        'public',
        'internal',
        'private',
        'protected',
        'data',
        'value',
        'final',
        'open',
        'abstract',
        'sealed',
        'enum',
        'companion',
        'annotation',
        'inline',
        'expect',
        'actual',
    }
)
KOTLIN_VISIBILITY_MODIFIERS = frozenset({'public', 'internal', 'private', 'protected'})


class SerdeAttrs(NamedTuple):
    rename: str | None
    rename_all: str | None
    rename_all_fields: str | None
    aliases: tuple[str, ...]
    skip: bool
    has_default: bool


class RustFieldSpec(NamedTuple):
    primary: str
    accepted: frozenset[str]
    required: bool


class RustVariantSchema(NamedTuple):
    allowed_fields: frozenset[str]
    required_fields: tuple[RustFieldSpec, ...]


class EmittedCommand(NamedTuple):
    symbol: str
    tag: str
    keys: frozenset[str]


class KotlinSubtype(NamedTuple):
    name: str
    serial_name: str | None
    keys: frozenset[str]


def strip_c_style_comments(source: str) -> str:
    out: list[str] = []
    i = 0
    n = len(source)
    in_string = False
    while i < n:
        ch = source[i]
        if in_string:
            out.append(ch)
            if ch == '\\' and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == '/' and i + 1 < n and source[i + 1] == '/':
            i += 2
            while i < n and source[i] != '\n':
                i += 1
            continue
        if ch == '/' and i + 1 < n and source[i + 1] == '*':
            i += 2
            while i + 1 < n and not (source[i] == '*' and source[i + 1] == '/'):
                if source[i] == '\n':
                    out.append('\n')
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def extract_balanced_block(
    text: str, open_idx: int, open_ch: str = '{', close_ch: str = '}'
) -> tuple[str, int]:
    if open_idx < 0 or open_idx >= len(text) or text[open_idx] != open_ch:
        raise ValueError(f'expected {open_ch!r} at index {open_idx}')
    depth = 0
    in_string = False
    i = open_idx
    n = len(text)
    while i < n:
        ch = text[i]
        if in_string:
            if ch == '\\' and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return text[open_idx + 1 : i], i + 1
        i += 1
    raise ValueError(f'unclosed {open_ch!r} starting at index {open_idx}')


def split_top_level(text: str, sep: str = ',') -> list[str]:
    parts: list[str] = []
    start = 0
    brace = paren = bracket = angle = 0
    in_string = False
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if in_string:
            if ch == '\\' and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch == '{':
            brace += 1
        elif ch == '}':
            brace = max(0, brace - 1)
        elif ch == '(':
            paren += 1
        elif ch == ')':
            paren = max(0, paren - 1)
        elif ch == '[':
            bracket += 1
        elif ch == ']':
            bracket = max(0, bracket - 1)
        elif ch == '<':
            angle += 1
        elif ch == '>':
            angle = max(0, angle - 1)
        elif ch == sep and brace == 0 and paren == 0 and bracket == 0 and angle == 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    parts.append(text[start:])
    return [part.strip() for part in parts if part.strip()]


def serde_snake_case(name: str) -> str:
    out: list[str] = []
    for i, ch in enumerate(name):
        if i > 0 and ch.isupper():
            out.append('_')
        out.append(ch.lower())
    return ''.join(out)


def serde_camel_case(name: str) -> str:
    parts = name.split('_')
    return parts[0] + ''.join(p[:1].upper() + p[1:] for p in parts[1:] if p)


def apply_serde_rule(name: str, rule: str | None) -> str:
    if not rule:
        return name
    if rule == 'snake_case':
        return serde_snake_case(name)
    if rule == 'camelCase':
        return serde_camel_case(name)
    if rule == 'kebab-case':
        return serde_snake_case(name).replace('_', '-')
    if rule == 'SCREAMING_SNAKE_CASE':
        return serde_snake_case(name).upper()
    if rule == 'lowercase':
        return name.lower()
    if rule == 'UPPERCASE':
        return name.upper()
    if rule == 'PascalCase':
        return ''.join(p[:1].upper() + p[1:] for p in name.split('_') if p)
    return name


def parse_serde_attrs(attr_text: str) -> SerdeAttrs:
    rename: str | None = None
    rename_all: str | None = None
    rename_all_fields: str | None = None
    aliases: list[str] = []
    skip = False
    has_default = False
    for match in re.finditer(r'#\[serde\(', attr_text):
        paren_idx = match.end() - 1
        inner, _ = extract_balanced_block(attr_text, paren_idx, '(', ')')
        for item in split_top_level(inner):
            if m := re.fullmatch(r'rename_all\s*=\s*"([^"]+)"', item):
                rename_all = m.group(1)
            elif m := re.fullmatch(r'rename_all_fields\s*=\s*"([^"]+)"', item):
                rename_all_fields = m.group(1)
            elif m := re.fullmatch(r'rename\s*=\s*"([^"]+)"', item):
                rename = m.group(1)
            elif m := re.fullmatch(r'rename\s*\(\s*deserialize\s*=\s*"([^"]+)"\s*\)', item):
                rename = m.group(1)
            elif m := re.fullmatch(r'alias\s*=\s*"([^"]+)"', item):
                aliases.append(m.group(1))
            elif item in ('skip', 'skip_deserializing'):
                skip = True
            elif item == 'default' or re.fullmatch(r'default\s*=\s*"[^"]+"', item):
                has_default = True
    return SerdeAttrs(
        rename=rename,
        rename_all=rename_all,
        rename_all_fields=rename_all_fields,
        aliases=tuple(aliases),
        skip=skip,
        has_default=has_default,
    )


def is_rust_option_type(type_expr: str) -> bool:
    compact = re.sub(r'\s+', '', type_expr)
    return bool(re.match(r'^(?:::(?:std|core)::option::|(?:std|core)::option::)?Option<', compact))


def consume_rust_attributes(text: str, pos: int) -> tuple[str, int]:
    attrs: list[str] = []
    n = len(text)
    while pos < n:
        while pos < n and text[pos].isspace():
            pos += 1
        if text.startswith('#[', pos):
            inner, next_pos = extract_balanced_block(text, pos + 1, '[', ']')
            attrs.append(f'#[{inner}]')
            pos = next_pos
        else:
            break
    return '\n'.join(attrs), pos


def parse_rust_enum_variants(
    body: str, rename_all: str | None, rename_all_fields: str | None
) -> dict[str, RustVariantSchema]:
    variants: dict[str, RustVariantSchema] = {}
    for entry in split_top_level(body):
        attr_text, pos = consume_rust_attributes(entry, 0)
        rest = entry[pos:].strip()
        if not rest:
            continue
        ident_match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)', rest)
        if not ident_match:
            continue
        variant_name = ident_match.group(1)
        v_attrs = parse_serde_attrs(attr_text)
        if v_attrs.skip:
            continue
        primary_tag = (
            v_attrs.rename
            if v_attrs.rename is not None
            else apply_serde_rule(variant_name, rename_all)
        )
        tags = (primary_tag, *v_attrs.aliases)
        allowed: set[str] = set()
        required: list[RustFieldSpec] = []
        after_ident = rest[ident_match.end() :].lstrip()
        if after_ident.startswith('{'):
            field_block, _ = extract_balanced_block(after_ident, 0, '{', '}')
            field_rule = (
                v_attrs.rename_all if v_attrs.rename_all is not None else rename_all_fields
            )
            for field_entry in split_top_level(field_block):
                f_attr_text, f_pos = consume_rust_attributes(field_entry, 0)
                f_rest = field_entry[f_pos:].strip()
                f_match = re.match(
                    r'^(?:pub(?:\([^)]*\))?\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$',
                    f_rest,
                    re.DOTALL,
                )
                if not f_match:
                    continue
                f_name = f_match.group(1)
                f_type = f_match.group(2).strip()
                f_attrs = parse_serde_attrs(f_attr_text)
                if f_attrs.skip:
                    continue
                f_key = (
                    f_attrs.rename
                    if f_attrs.rename is not None
                    else apply_serde_rule(f_name, field_rule)
                )
                accepted = frozenset((f_key, *f_attrs.aliases))
                allowed.update(accepted)
                is_required = (not f_attrs.has_default) and (not is_rust_option_type(f_type))
                if is_required:
                    required.append(RustFieldSpec(primary=f_key, accepted=accepted, required=True))
        variant_schema = RustVariantSchema(
            allowed_fields=frozenset(allowed),
            required_fields=tuple(required),
        )
        for tag in tags:
            variants[tag] = variant_schema
    return variants


def parse_rust_command_schema(
    source: str, enum_names: tuple[str, ...] = ('HostIntent', 'AdapterEvent')
) -> dict[str, RustVariantSchema]:
    clean = strip_c_style_comments(source)
    schema: dict[str, RustVariantSchema] = {}
    found_enums: set[str] = set()
    pattern = re.compile(
        r'((?:\s*#\[(?:[^\[\]]|\[[^\]]*\])*\])*)\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{'
    )
    for match in pattern.finditer(clean):
        enum_name = match.group(2)
        if enum_name not in enum_names:
            continue
        found_enums.add(enum_name)
        attrs = parse_serde_attrs(match.group(1))
        body, _ = extract_balanced_block(clean, match.end() - 1, '{', '}')
        variants = parse_rust_enum_variants(body, attrs.rename_all, attrs.rename_all_fields)
        schema.update(variants)
    missing = [name for name in enum_names if name not in found_enums]
    if missing:
        raise ValueError(f'failed to locate Rust command enum(s): {", ".join(missing)}')
    return schema


def parse_swift_coding_keys(enum_body: str) -> dict[str, str]:
    match = re.search(r'\benum\s+CodingKeys\b[^{]*\{', enum_body)
    if not match:
        return {}
    block, _ = extract_balanced_block(enum_body, match.end() - 1, '{', '}')
    case_starts: list[int] = []
    in_string = False
    i = 0
    n = len(block)
    while i < n:
        ch = block[i]
        if in_string:
            if ch == '\\' and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif (
            (i == 0 or not (block[i - 1].isalnum() or block[i - 1] == '_'))
            and block.startswith('case', i)
            and i + 4 < n
            and block[i + 4].isspace()
        ):
            case_starts.append(i)
        i += 1

    keys: dict[str, str] = {}
    for idx, start in enumerate(case_starts):
        end = case_starts[idx + 1] if idx + 1 < len(case_starts) else len(block)
        chunk = block[start + len('case') : end].strip().rstrip(';')
        for stmt in split_top_level(chunk, ';'):
            for item in split_top_level(stmt, ','):
                if m := re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"', item):
                    keys[m.group(1)] = m.group(2)
                elif m := re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)', item):
                    keys[m.group(1)] = m.group(1)
    return keys


def split_swift_switch_arms(switch_body: str) -> list[tuple[str, str]]:
    case_starts: list[int] = []
    brace = paren = bracket = 0
    in_string = False
    i = 0
    n = len(switch_body)
    while i < n:
        ch = switch_body[i]
        if in_string:
            if ch == '\\' and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch == '{':
            brace += 1
        elif ch == '}':
            brace = max(0, brace - 1)
        elif ch == '(':
            paren += 1
        elif ch == ')':
            paren = max(0, paren - 1)
        elif ch == '[':
            bracket += 1
        elif ch == ']':
            bracket = max(0, bracket - 1)
        elif brace == 0 and paren == 0 and bracket == 0:
            if (i == 0 or not (switch_body[i - 1].isalnum() or switch_body[i - 1] == '_')) and (
                switch_body.startswith('case ', i)
                or switch_body.startswith('case\n', i)
                or switch_body.startswith('default:', i)
                or switch_body.startswith('default ', i)
            ):
                case_starts.append(i)
        i += 1

    arms: list[tuple[str, str]] = []
    for idx, start in enumerate(case_starts):
        end = case_starts[idx + 1] if idx + 1 < len(case_starts) else len(switch_body)
        chunk = switch_body[start:end].strip()
        p = b = k = 0
        s = False
        colon_pos = -1
        j = 0
        while j < len(chunk):
            c = chunk[j]
            if s:
                if c == '\\' and j + 1 < len(chunk):
                    j += 2
                    continue
                if c == '"':
                    s = False
                j += 1
                continue
            if c == '"':
                s = True
            elif c == '(':
                p += 1
            elif c == ')':
                p = max(0, p - 1)
            elif c == '{':
                b += 1
            elif c == '}':
                b = max(0, b - 1)
            elif c == '[':
                k += 1
            elif c == ']':
                k = max(0, k - 1)
            elif c == ':' and p == 0 and b == 0 and k == 0:
                colon_pos = j
                break
            j += 1
        if colon_pos != -1:
            arms.append((chunk[:colon_pos].strip(), chunk[colon_pos + 1 :].strip()))
    return arms


def extract_swift_case_names(arm_header: str) -> list[str]:
    without_parens: list[str] = []
    depth = 0
    for ch in arm_header:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth = max(0, depth - 1)
        elif depth == 0:
            without_parens.append(ch)
    header_flat = re.sub(r'\bwhere\b.*', '', ''.join(without_parens), flags=re.DOTALL)
    return re.findall(r'\.([A-Za-z_][A-Za-z0-9_]*)', header_flat)


def extract_swift_encoded_keys(code: str, coding_keys: dict[str, str]) -> set[str]:
    raw_keys = re.findall(
        r'forKey\s*:\s*(?:(?:Self\s*\.\s*)?CodingKeys\s*)?\.\s*([A-Za-z_][A-Za-z0-9_]*)',
        code,
    )
    return {coding_keys.get(k, k) for k in raw_keys if coding_keys.get(k, k) != 'type'}


def parse_swift_emitted_commands(source: str, enum_name: str) -> list[EmittedCommand]:
    clean = strip_c_style_comments(source)
    enum_match = re.search(rf'\benum\s+{re.escape(enum_name)}\b[^{{]*\{{', clean)
    if not enum_match:
        raise ValueError(f'failed to locate Swift enum {enum_name}')
    enum_body, _ = extract_balanced_block(clean, enum_match.end() - 1, '{', '}')
    coding_keys = parse_swift_coding_keys(enum_body)

    type_prop = re.search(r'\bvar\s+(?:commandType|eventType)\s*:\s*String\s*\{', enum_body)
    if not type_prop:
        raise ValueError(f'failed to locate commandType/eventType in Swift enum {enum_name}')
    type_body, _ = extract_balanced_block(enum_body, type_prop.end() - 1, '{', '}')
    type_switch = re.search(r'\bswitch\s+self\s*\{', type_body)
    if not type_switch:
        raise ValueError(f'failed to locate switch self in {enum_name} type property')
    type_switch_body, _ = extract_balanced_block(type_body, type_switch.end() - 1, '{', '}')
    case_to_tags: dict[str, list[str]] = {}
    for header, arm_body in split_swift_switch_arms(type_switch_body):
        tags = re.findall(r'"((?:[^"\\]|\\.)*)"', arm_body)
        if not tags:
            continue
        targets = ['default'] if re.match(r'^default\b', header) else extract_swift_case_names(header)
        for case_name in targets:
            existing = case_to_tags.setdefault(case_name, [])
            for tag in tags:
                if tag not in existing:
                    existing.append(tag)

    encode_match = re.search(r'\bfunc\s+encode\s*\([^)]*\)\s*throws\s*\{', enum_body)
    if not encode_match:
        raise ValueError(f'failed to locate encode(to:) in Swift enum {enum_name}')
    encode_body, _ = extract_balanced_block(enum_body, encode_match.end() - 1, '{', '}')
    encode_switch = re.search(r'\bswitch\s+self\s*\{', encode_body)
    if not encode_switch:
        raise ValueError(f'failed to locate switch self in {enum_name}.encode(to:)')
    encode_switch_body, encode_switch_end = extract_balanced_block(
        encode_body, encode_switch.end() - 1, '{', '}'
    )
    shared_keys = extract_swift_encoded_keys(
        encode_body[: encode_switch.start()] + '\n' + encode_body[encode_switch_end:],
        coding_keys,
    )

    case_to_keys: dict[str, set[str]] = {}
    for header, arm_body in split_swift_switch_arms(encode_switch_body):
        resolved = extract_swift_encoded_keys(arm_body, coding_keys)
        if re.match(r'^default\b', header):
            if resolved:
                raise ValueError(
                    f"Swift {enum_name}.encode(to:) has a 'default:' arm encoding extra JSON "
                    f"key(s) {sorted(resolved)}; switch exhaustively over enum cases so every key "
                    'is verified against Rust.'
                )
            continue
        for case_name in extract_swift_case_names(header):
            case_to_keys.setdefault(case_name, set()).update(resolved)

    emitted: list[EmittedCommand] = []
    for case_name, tags in case_to_tags.items():
        keys = frozenset(case_to_keys.get(case_name, set()) | shared_keys)
        for tag in tags:
            emitted.append(EmittedCommand(symbol=f'{enum_name}.{case_name}', tag=tag, keys=keys))
    for case_name, keys in case_to_keys.items():
        if case_name not in case_to_tags:
            raise ValueError(
                f'Swift {enum_name}.{case_name} is encoded in encode(to:) with keys {sorted(keys)} '
                'but missing from commandType/eventType'
            )
    return emitted


def consume_kotlin_annotation(text: str, pos: int) -> tuple[str, int]:
    n = len(text)
    start = pos
    pos += 1
    while pos < n and (text[pos].isalnum() or text[pos] in ('_', '.', ':')):
        pos += 1
    ws_pos = pos
    while ws_pos < n and text[ws_pos].isspace():
        ws_pos += 1
    if ws_pos < n and text[ws_pos] == '(':
        _, pos = extract_balanced_block(text, ws_pos, '(', ')')
    return text[start:pos], pos


def parse_kotlin_constructor_keys(params_text: str) -> frozenset[str]:
    keys: set[str] = set()
    for param in split_top_level(params_text):
        pos = 0
        n = len(param)
        leading_annotations: list[str] = []
        while pos < n:
            while pos < n and param[pos].isspace():
                pos += 1
            if pos < n and param[pos] == '@':
                ann, pos = consume_kotlin_annotation(param, pos)
                leading_annotations.append(ann)
                continue
            break
        rest = param[pos:]
        val_match = re.search(r'\b(?:val|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:', rest)
        if not val_match:
            continue
        serial_name: str | None = None
        for ann in leading_annotations:
            if m := re.match(r'^@(?:[A-Za-z0-9_.]*\.)?SerialName\s*\(\s*"([^"]+)"\s*\)$', ann):
                serial_name = m.group(1)
        keys.add(serial_name if serial_name is not None else val_match.group(1))
    return frozenset(keys)


def skip_kotlin_string(text: str, pos: int) -> int:
    n = len(text)
    if text.startswith('"""', pos):
        end = text.find('"""', pos + 3)
        return end + 3 if end != -1 else n
    pos += 1
    while pos < n:
        if text[pos] == '\\' and pos + 1 < n:
            pos += 2
            continue
        if text[pos] == '"':
            return pos + 1
        pos += 1
    return n


def read_kotlin_identifier(text: str, pos: int) -> tuple[str | None, int]:
    n = len(text)
    if pos >= n or not (text[pos].isalpha() or text[pos] == '_'):
        return None, pos
    start = pos
    pos += 1
    while pos < n and (text[pos].isalnum() or text[pos] == '_'):
        pos += 1
    return text[start:pos], pos


def parse_kotlin_supertype_names(text: str, pos: int) -> tuple[list[str], int]:
    n = len(text)
    supertypes: list[str] = []
    while pos < n:
        while pos < n and text[pos].isspace():
            pos += 1
        ident, next_pos = read_kotlin_identifier(text, pos)
        if ident is None:
            break
        parts = [ident]
        pos = next_pos
        while True:
            dot_pos = pos
            while dot_pos < n and text[dot_pos].isspace():
                dot_pos += 1
            if dot_pos < n and text[dot_pos] == '.':
                dot_pos += 1
                while dot_pos < n and text[dot_pos].isspace():
                    dot_pos += 1
                seg, after_seg = read_kotlin_identifier(text, dot_pos)
                if seg is None:
                    break
                parts.append(seg)
                pos = after_seg
            else:
                break
        supertypes.append(parts[-1])
        while pos < n and text[pos].isspace():
            pos += 1
        if pos < n and text[pos] == '<':
            _, pos = extract_balanced_block(text, pos, '<', '>')
            while pos < n and text[pos].isspace():
                pos += 1
        if pos < n and text[pos] == '(':
            _, pos = extract_balanced_block(text, pos, '(', ')')
            while pos < n and text[pos].isspace():
                pos += 1
        if pos < n and text[pos] == ',':
            pos += 1
            continue
        break
    return supertypes, pos


def scan_kotlin_subtypes(text: str, interface_name: str) -> list[KotlinSubtype]:
    subtypes: list[KotlinSubtype] = []
    annotations: list[str] = []
    modifiers: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
            continue
        if ch == '@':
            ann, i = consume_kotlin_annotation(text, i)
            if not ann.startswith('@file:'):
                annotations.append(ann)
            continue
        if ch == '{':
            _, i = extract_balanced_block(text, i, '{', '}')
            annotations.clear()
            modifiers.clear()
            continue
        if ch == '(':
            _, i = extract_balanced_block(text, i, '(', ')')
            continue
        if ch == '"':
            i = skip_kotlin_string(text, i)
            continue
        if ch == ';':
            annotations.clear()
            modifiers.clear()
            i += 1
            continue
        word, next_i = read_kotlin_identifier(text, i)
        if word is None:
            i += 1
            continue
        i = next_i
        if word in KOTLIN_MODIFIERS:
            modifiers.append(word)
            continue
        if word in ('class', 'object'):
            decl_annotations = list(annotations)
            decl_modifiers = list(modifiers)
            annotations.clear()
            modifiers.clear()
            if 'enum' in decl_modifiers or 'companion' in decl_modifiers:
                continue
            while i < n and text[i].isspace():
                i += 1
            type_name, after_name = read_kotlin_identifier(text, i)
            if type_name is None:
                continue
            i = after_name
            while i < n and text[i].isspace():
                i += 1
            if i < n and text[i] == '<':
                _, i = extract_balanced_block(text, i, '<', '>')
            params_text: str | None = None
            if word == 'class':
                ctor_pos = i
                while ctor_pos < n:
                    while ctor_pos < n and text[ctor_pos].isspace():
                        ctor_pos += 1
                    if ctor_pos < n and text[ctor_pos] == '@':
                        _, ctor_pos = consume_kotlin_annotation(text, ctor_pos)
                        continue
                    mod_word, after_mod = read_kotlin_identifier(text, ctor_pos)
                    if mod_word in KOTLIN_VISIBILITY_MODIFIERS:
                        ctor_pos = after_mod
                        continue
                    if mod_word == 'constructor':
                        ctor_pos = after_mod
                        while ctor_pos < n and text[ctor_pos].isspace():
                            ctor_pos += 1
                    break
                if ctor_pos < n and text[ctor_pos] == '(':
                    params_text, i = extract_balanced_block(text, ctor_pos, '(', ')')
            while i < n and text[i].isspace():
                i += 1
            supertypes: list[str] = []
            if i < n and text[i] == ':':
                supertypes, i = parse_kotlin_supertype_names(text, i + 1)
            while i < n and text[i].isspace():
                i += 1
            if i < n and text[i] == '{':
                _, i = extract_balanced_block(text, i, '{', '}')
            if interface_name in supertypes:
                serial_name: str | None = None
                for ann in decl_annotations:
                    if m := re.match(
                        r'^@(?:[A-Za-z0-9_.]*\.)?SerialName\s*\(\s*"([^"]+)"\s*\)$', ann
                    ):
                        serial_name = m.group(1)
                keys = parse_kotlin_constructor_keys(params_text) if params_text else frozenset()
                subtypes.append(KotlinSubtype(name=type_name, serial_name=serial_name, keys=keys))
            continue
        if word in ('interface', 'package', 'import', 'fun', 'val', 'var', 'typealias'):
            annotations.clear()
            modifiers.clear()
            continue
        annotations.clear()
        modifiers.clear()
    return subtypes


def parse_kotlin_when_map(iface_body: str) -> dict[str, str]:
    when_map: dict[str, str] = {}
    when_match = re.search(r'\bwhen\s*\(\s*this\s*\)\s*\{', iface_body)
    if not when_match:
        return when_map
    when_body, _ = extract_balanced_block(iface_body, when_match.end() - 1, '{', '}')
    for line in when_body.splitlines():
        if '->' not in line:
            continue
        lhs, rhs = line.split('->', 1)
        tag_match = re.search(r'"([^"]+)"', rhs)
        if not tag_match:
            continue
        tag = tag_match.group(1)
        for branch in split_top_level(lhs, ','):
            m = re.fullmatch(
                r'(?:is\s+)?(?:[A-Za-z_][A-Za-z0-9_]*\.)*([A-Za-z_][A-Za-z0-9_]*)',
                branch.strip(),
            )
            if m and m.group(1) != 'else':
                when_map[m.group(1)] = tag
    return when_map


def parse_kotlin_emitted_commands(source: str, interface_name: str) -> list[EmittedCommand]:
    clean = strip_c_style_comments(source)
    iface_match = re.search(rf'\bsealed\s+interface\s+{re.escape(interface_name)}\b[^{{]*\{{', clean)
    if not iface_match:
        raise ValueError(f'failed to locate Kotlin sealed interface {interface_name}')
    iface_body, iface_end = extract_balanced_block(clean, iface_match.end() - 1, '{', '}')
    when_map = parse_kotlin_when_map(iface_body)

    nested_subtypes = scan_kotlin_subtypes(iface_body, interface_name)
    outer_text = clean[: iface_match.start()] + '\n' + clean[iface_end:]
    top_level_subtypes = scan_kotlin_subtypes(outer_text, interface_name)
    all_subtypes = nested_subtypes + top_level_subtypes
    if not all_subtypes:
        raise ValueError(f'no subtypes implementing Kotlin sealed interface {interface_name} found')

    errors: list[str] = []
    emitted: list[EmittedCommand] = []
    by_name: dict[str, KotlinSubtype] = {}
    for subtype in all_subtypes:
        by_name[subtype.name] = subtype
        if subtype.serial_name is None:
            suggested = when_map.get(subtype.name, '<rust_tag>')
            errors.append(
                f'Kotlin {interface_name}.{subtype.name} lacks @SerialName("{suggested}"); '
                'every polymorphic command/event subtype must declare @SerialName("<rust_tag>").'
            )
            continue
        if subtype.name in when_map and when_map[subtype.name] != subtype.serial_name:
            errors.append(
                f'Kotlin {interface_name}.{subtype.name}: @SerialName("{subtype.serial_name}") '
                f'disagrees with commandType/eventType "{when_map[subtype.name]}".'
            )
        emitted.append(
            EmittedCommand(
                symbol=f'{interface_name}.{subtype.name}',
                tag=subtype.serial_name,
                keys=subtype.keys,
            )
        )

    if when_map:
        for type_name, tag in when_map.items():
            if type_name not in by_name:
                errors.append(
                    f'Kotlin {interface_name}.{type_name} appears in commandType/eventType '
                    f'("{tag}") but no subtype declaration implementing {interface_name} was parsed.'
                )
        for type_name in by_name:
            if type_name not in when_map:
                errors.append(
                    f'Kotlin {interface_name}.{type_name} implements {interface_name} '
                    'but is missing from commandType/eventType when(this).'
                )

    if errors:
        raise ValueError('\n'.join(errors))
    return emitted


def validate_host_commands(
    rust_schema: dict[str, RustVariantSchema],
    emitted: list[EmittedCommand],
    source_label: str,
) -> list[str]:
    errors: list[str] = []
    for cmd in emitted:
        variant = rust_schema.get(cmd.tag)
        if variant is None:
            errors.append(
                f"{source_label} ({cmd.symbol}): unknown command type tag '{cmd.tag}' is not "
                f"accepted by crates/koe-runtime/src/command.rs; add the variant to "
                f"HostIntent/AdapterEvent or fix/remove the tag in {source_label}."
            )
            continue
        for key in sorted(cmd.keys - variant.allowed_fields):
            expected = (
                ', '.join(sorted(variant.allowed_fields)) if variant.allowed_fields else '(none)'
            )
            errors.append(
                f"{source_label} ({cmd.symbol}): command tag '{cmd.tag}' emits unknown JSON field "
                f"'{key}' which crates/koe-runtime/src/command.rs rejects via "
                f"#[serde(deny_unknown_fields)] (expected fields: {expected}); "
                f"fix the field name in {source_label} or add it to the Rust variant."
            )
        for req in variant.required_fields:
            if not (req.accepted & cmd.keys):
                errors.append(
                    f"{source_label} ({cmd.symbol}): command tag '{cmd.tag}' is missing required "
                    f"JSON field '{req.primary}' expected by crates/koe-runtime/src/command.rs; "
                    f"emit '{req.primary}' in {source_label} or mark the field Option/default in Rust."
                )
    return errors


def assert_host_commands_match(
    rust_schema: dict[str, RustVariantSchema],
    emitted: list[EmittedCommand],
    source_label: str,
) -> None:
    errors = validate_host_commands(rust_schema, emitted, source_label)
    if errors:
        raise ValueError('\n'.join(errors))


class CFunctionSignature(NamedTuple):
    return_type: str
    param_types: tuple[str, ...]


class CAbiSurface(NamedTuple):
    functions: dict[str, CFunctionSignature]
    structs: dict[str, tuple[tuple[str, str], ...]]
    callbacks: dict[str, CFunctionSignature]


RUST_PRIMITIVE_TO_C = {
    '()': 'void',
    'bool': 'bool',
    'u8': 'uint8_t',
    'u16': 'uint16_t',
    'u32': 'uint32_t',
    'u64': 'uint64_t',
    'i8': 'int8_t',
    'i16': 'int16_t',
    'i32': 'int32_t',
    'i64': 'int64_t',
    'usize': 'size_t',
    'isize': 'ptrdiff_t',
    'c_char': 'char',
    'c_void': 'void',
}


def rust_type_to_c(type_expr: str, callback_names: frozenset[str]) -> str:
    expr = re.sub(r'\s+', ' ', type_expr.strip())
    if not expr or expr == '()':
        return 'void'
    if expr.startswith('[') and expr.endswith(']'):
        inner = expr[1:-1].strip()
        elem_expr, count_expr = inner.rsplit(';', 1)
        count = str(eval_const_int_expr(count_expr.strip()))
        return f'{rust_type_to_c(elem_expr, callback_names)}[{count}]'
    if expr.startswith('*const '):
        inner = rust_type_to_c(expr[len('*const ') :], callback_names)
        return f'const {inner}*'
    if expr.startswith('*mut '):
        inner = rust_type_to_c(expr[len('*mut ') :], callback_names)
        return f'{inner}*'
    opt_match = re.fullmatch(
        r'(?:::(?:std|core)::option::|(?:std|core)::option::)?Option<\s*(.+?)\s*>', expr
    )
    if opt_match:
        inner = opt_match.group(1).strip().rsplit('::', 1)[-1]
        if inner in callback_names:
            return inner
        raise ValueError(f'unsupported Option<T> in C ABI signature: {expr}')
    leaf = expr.rsplit('::', 1)[-1]
    return RUST_PRIMITIVE_TO_C.get(leaf, leaf)


def normalize_c_type(raw_type: str) -> str:
    text = re.sub(r'\s+', ' ', raw_type.strip())
    text = re.sub(r'\s*\*\s*', '*', text)
    text = re.sub(r'\s*\[\s*', '[', text)
    text = re.sub(r'\s*\]', ']', text)
    return text


def parse_c_decl_type_and_name(decl: str) -> tuple[str, str]:
    clean = re.sub(r'\s+', ' ', decl.strip())
    arr_suffix = ''
    while True:
        arr_match = re.search(r'\[\s*([^\]]+)\s*\]\s*$', clean)
        if not arr_match:
            break
        arr_suffix = f'[{eval_const_int_expr(arr_match.group(1))}]' + arr_suffix
        clean = clean[: arr_match.start()].rstrip()
    name_match = re.search(r'([A-Za-z_][A-Za-z0-9_]*)\s*$', clean)
    if not name_match:
        raise ValueError(f'failed to extract C declarator name from: {decl!r}')
    name = name_match.group(1)
    type_part = clean[: name_match.start()].strip()
    return name, normalize_c_type(type_part + arr_suffix)


def parse_c_param_types(params_text: str) -> tuple[str, ...]:
    stripped = params_text.strip()
    if not stripped or stripped == 'void':
        return ()
    types: list[str] = []
    for param in split_top_level(stripped, ','):
        _, c_type = parse_c_decl_type_and_name(param)
        types.append(c_type)
    return tuple(types)


def collect_rust_host_api_sources(root_dir: Path) -> list[str]:
    sources: list[str] = []
    for path in sorted(root_dir.rglob('*.rs')):
        rel = path.relative_to(root_dir)
        if path.name.endswith('_tests.rs') or path.name == 'tests.rs' or 'tests' in rel.parts[:-1]:
            continue
        sources.append(path.read_text(encoding='utf-8'))
    return sources


def has_repr_c(attrs: str) -> bool:
    for repr_match in re.finditer(r'#\[repr\s*\(', attrs):
        inner, _ = extract_balanced_block(attrs, repr_match.end() - 1, '(', ')')
        tokens = [part.strip() for part in split_top_level(inner, ',')]
        if 'C' in tokens:
            return True
    return False


def extract_exported_c_symbol(attrs: str, rust_fn_name: str) -> str | None:
    export_match = re.search(
        r'#\[(?:unsafe\s*\(\s*export_name\s*=\s*"([^"]+)"\s*\)|export_name\s*=\s*"([^"]+)")\]',
        attrs,
    )
    if export_match:
        return export_match.group(1) or export_match.group(2)
    if re.search(r'#\[(?:unsafe\s*\(\s*no_mangle\s*\)|no_mangle)\]', attrs):
        return rust_fn_name
    return None


def strip_extern_c_wrappers(body: str) -> str:
    while True:
        extern_match = re.search(r'\bextern\s+"C"\s*\{', body)
        if not extern_match:
            break
        inner, after_brace = extract_balanced_block(body, extern_match.end() - 1, '{', '}')
        body = body[: extern_match.start()] + '\n' + inner + '\n' + body[after_brace:]
    return re.sub(r'\bextern\s+"C"\s+', '', body)


def parse_rust_c_abi_surface(sources: list[str]) -> CAbiSurface:
    cleaned = [strip_c_style_comments(src) for src in sources]
    callbacks: dict[str, CFunctionSignature] = {}
    structs: dict[str, tuple[tuple[str, str], ...]] = {}
    functions: dict[str, CFunctionSignature] = {}

    cb_pattern = re.compile(
        r'\bpub\s+type\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:unsafe\s+)?extern\s+"C"\s+fn\s*\('
    )
    for src in cleaned:
        for m in cb_pattern.finditer(src):
            cb_name = m.group(1)
            params_text, after_params = extract_balanced_block(src, m.end() - 1, '(', ')')
            semi_idx = src.find(';', after_params)
            if semi_idx == -1:
                raise ValueError(f'unterminated Rust callback typedef: {cb_name}')
            tail = src[after_params:semi_idx].strip()
            ret_expr = tail[2:].strip() if tail.startswith('->') else '()'
            param_types = tuple(
                rust_type_to_c(p.split(':', 1)[-1], frozenset())
                for p in split_top_level(params_text, ',')
            )
            callbacks[cb_name] = CFunctionSignature(
                return_type=rust_type_to_c(ret_expr, frozenset()),
                param_types=param_types,
            )

    cb_names = frozenset(callbacks)

    attr_stack = r'((?:\s*#\[(?:[^\[\]]|\[[^\]]*\])*\])+)'
    struct_pattern = re.compile(attr_stack + r'\s*pub\s+struct\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{')
    for src in cleaned:
        for m in struct_pattern.finditer(src):
            if not has_repr_c(m.group(1)):
                continue
            struct_name = m.group(2)
            body, _ = extract_balanced_block(src, m.end() - 1, '{', '}')
            fields: list[tuple[str, str]] = []
            for entry in split_top_level(body, ','):
                _, pos = consume_rust_attributes(entry, 0)
                rest = entry[pos:].strip()
                f_match = re.match(
                    r'^(?:pub(?:\([^)]*\))?\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$',
                    rest,
                    re.DOTALL,
                )
                if not f_match:
                    raise ValueError(
                        f'failed to parse #[repr(C)] field in struct {struct_name}: {entry!r}'
                    )
                fields.append((f_match.group(1), rust_type_to_c(f_match.group(2), cb_names)))
            structs[struct_name] = tuple(fields)

    fn_pattern = re.compile(
        attr_stack
        + r'\s*(?:pub(?:\([^)]*\))?\s+)?(?:unsafe\s+)?extern\s+"C"\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\('
    )
    for src in cleaned:
        for m in fn_pattern.finditer(src):
            fn_name = extract_exported_c_symbol(m.group(1), m.group(2))
            if fn_name is None:
                continue
            params_text, after_params = extract_balanced_block(src, m.end() - 1, '(', ')')
            brace_idx = src.find('{', after_params)
            if brace_idx == -1:
                raise ValueError(f'unterminated Rust extern C fn: {fn_name}')
            tail = src[after_params:brace_idx].strip()
            ret_expr = tail[2:].strip() if tail.startswith('->') else '()'
            param_types: list[str] = []
            for param in split_top_level(params_text, ','):
                if ':' not in param:
                    raise ValueError(f'malformed parameter {param!r} in Rust fn {fn_name}')
                _, p_type = param.split(':', 1)
                param_types.append(rust_type_to_c(p_type, cb_names))
            functions[fn_name] = CFunctionSignature(
                return_type=rust_type_to_c(ret_expr, cb_names),
                param_types=tuple(param_types),
            )

    return CAbiSurface(functions=functions, structs=structs, callbacks=callbacks)


def parse_c_header_abi_surface(header_source: str) -> CAbiSurface:
    clean = strip_c_style_comments(header_source)
    lines = [line for line in clean.splitlines() if not line.lstrip().startswith('#')]
    body = strip_extern_c_wrappers('\n'.join(lines))

    callbacks: dict[str, CFunctionSignature] = {}
    structs: dict[str, tuple[tuple[str, str], ...]] = {}
    functions: dict[str, CFunctionSignature] = {}

    i = 0
    n = len(body)
    while i < n:
        while i < n and body[i].isspace():
            i += 1
        if i >= n:
            break
        if body[i] == ';':
            i += 1
            continue
        if re.match(r'typedef\s+struct\b', body[i:]):
            brace_pos = body.find('{', i)
            if brace_pos == -1:
                raise ValueError('unterminated typedef struct in C header')
            struct_body, after_brace = extract_balanced_block(body, brace_pos, '{', '}')
            semi_pos = body.find(';', after_brace)
            if semi_pos == -1:
                raise ValueError('missing semicolon after typedef struct in C header')
            alias_name = body[after_brace:semi_pos].strip()
            fields: list[tuple[str, str]] = []
            for stmt in split_top_level(struct_body, ';'):
                fields.append(parse_c_decl_type_and_name(stmt))
            structs[alias_name] = tuple(fields)
            i = semi_pos + 1
            continue
        semi_pos = body.find(';', i)
        if semi_pos == -1:
            raise ValueError(f'unterminated declaration in C header near: {body[i : i + 60]!r}')
        stmt = re.sub(r'\s+', ' ', body[i:semi_pos].strip())
        i = semi_pos + 1
        cb_match = re.fullmatch(
            r'typedef\s+(.+?)\s*\(\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\((.*)\)', stmt
        )
        if cb_match:
            ret_type = normalize_c_type(cb_match.group(1))
            cb_name = cb_match.group(2)
            callbacks[cb_name] = CFunctionSignature(
                return_type=ret_type,
                param_types=parse_c_param_types(cb_match.group(3)),
            )
            continue
        fn_match = re.fullmatch(r'(.+?)\s*\((.*)\)', stmt)
        if not fn_match:
            raise ValueError(f'unrecognized C header declaration: {stmt!r}')
        fn_name, ret_type = parse_c_decl_type_and_name(fn_match.group(1))
        functions[fn_name] = CFunctionSignature(
            return_type=ret_type,
            param_types=parse_c_param_types(fn_match.group(2)),
        )

    return CAbiSurface(functions=functions, structs=structs, callbacks=callbacks)


def validate_c_abi_parity(rust_abi: CAbiSurface, header_abi: CAbiSurface) -> list[str]:
    errors: list[str] = []

    for label, rust_map, header_map in (
        ('callback typedef', rust_abi.callbacks, header_abi.callbacks),
        ('extern "C" function', rust_abi.functions, header_abi.functions),
    ):
        for name in sorted(set(rust_map) - set(header_map)):
            errors.append(f'Rust exports {label} {name!r}, missing from koe_host_api.h')
        for name in sorted(set(header_map) - set(rust_map)):
            errors.append(f'koe_host_api.h declares {label} {name!r}, missing from Rust exports')
        for name in sorted(set(rust_map) & set(header_map)):
            r_sig = rust_map[name]
            h_sig = header_map[name]
            if r_sig.return_type != h_sig.return_type:
                errors.append(
                    f'{label} {name!r} return type mismatch: Rust={r_sig.return_type!r}, '
                    f'header={h_sig.return_type!r}'
                )
            if len(r_sig.param_types) != len(h_sig.param_types):
                errors.append(
                    f'{label} {name!r} parameter count mismatch: Rust={len(r_sig.param_types)}, '
                    f'header={len(h_sig.param_types)}'
                )
            elif r_sig.param_types != h_sig.param_types:
                errors.append(
                    f'{label} {name!r} parameter types mismatch: Rust={r_sig.param_types!r}, '
                    f'header={h_sig.param_types!r}'
                )

    for name in sorted(set(rust_abi.structs) - set(header_abi.structs)):
        errors.append(f'Rust defines #[repr(C)] struct {name!r}, missing from koe_host_api.h')
    for name in sorted(set(header_abi.structs) - set(rust_abi.structs)):
        errors.append(f'koe_host_api.h defines struct {name!r}, missing from Rust #[repr(C)]')
    for name in sorted(set(rust_abi.structs) & set(header_abi.structs)):
        if rust_abi.structs[name] != header_abi.structs[name]:
            errors.append(
                f'struct {name!r} layout mismatch: Rust={rust_abi.structs[name]!r}, '
                f'header={header_abi.structs[name]!r}'
            )

    return errors


def assert_c_abi_parity(rust_abi: CAbiSurface, header_abi: CAbiSurface) -> None:
    errors = validate_c_abi_parity(rust_abi, header_abi)
    if errors:
        raise ValueError('\n'.join(errors))


def eval_const_int_expr(expr: str) -> int:
    node = ast.parse(expr.strip().replace('_', ''), mode='eval').body

    def _eval(n: ast.AST) -> int:
        if isinstance(n, ast.Constant) and isinstance(n.value, int) and not isinstance(n.value, bool):
            return n.value
        if isinstance(n, ast.BinOp):
            left = _eval(n.left)
            right = _eval(n.right)
            if isinstance(n.op, ast.Mult):
                return left * right
            if isinstance(n.op, ast.Add):
                return left + right
            if isinstance(n.op, ast.Sub):
                return left - right
            if isinstance(n.op, ast.LShift):
                return left << right
        raise ValueError(f'unsupported integer constant expression: {expr!r}')

    return _eval(node)


def extract_const_int_value(source: str, pattern: str, label: str) -> int:
    clean = strip_c_style_comments(source)
    match = re.search(pattern, clean)
    if not match:
        raise ValueError(f'failed to locate constant {label}')
    return eval_const_int_expr(match.group(1))


def validate_command_size_limits(
    runtime_lib_src: str, local_bridge_src: str, client_jni_src: str
) -> list[str]:
    errors: list[str] = []
    specs = (
        (
            runtime_lib_src,
            r'\bpub\s+const\s+MAX_COMMAND_JSON_BYTES\s*:\s*usize\s*=\s*([^;]+);',
            'crates/koe-runtime/src/lib.rs::MAX_COMMAND_JSON_BYTES',
        ),
        (
            local_bridge_src,
            r'\b(?:pub\s+)?const\s+MAX_LINE_BYTES\s*:\s*u64\s*=\s*([^;]+);',
            'crates/koe-host-api/src/local_bridge.rs::MAX_LINE_BYTES',
        ),
        (
            client_jni_src,
            r'\bconstexpr\s+size_t\s+kMaxCommandJsonBytes\s*=\s*([^;]+);',
            'platforms/android/native/client_jni.cpp::kMaxCommandJsonBytes',
        ),
    )
    for src, pattern, label in specs:
        try:
            value = extract_const_int_value(src, pattern, label)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        if value != EXPECTED_MAX_COMMAND_JSON_BYTES:
            errors.append(
                f'{label} is {value} bytes, expected {EXPECTED_MAX_COMMAND_JSON_BYTES} (2 * 1024 * 1024)'
            )
    return errors


def find_client_chinese_status_checks(
    files: list[tuple[str, str]],
) -> list[str]:
    pattern = re.compile(
        '"(?:' + '|'.join(re.escape(token) for token in FORBIDDEN_RECORD_STATUS_LITERALS) + ')"'
    )
    violations: list[str] = []
    for rel_path, source in files:
        clean = strip_c_style_comments(source)
        for lineno, line in enumerate(clean.splitlines(), start=1):
            for match in pattern.finditer(line):
                violations.append(
                    f'{rel_path}:{lineno}: forbidden client record status literal {match.group(0)}'
                )
    return violations


class HostContractParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rust_schema = parse_rust_command_schema(RUST_COMMAND_RS.read_text(encoding='utf-8'))

    def test_rust_schema_extracts_intents_adapter_events_and_required_fields(self) -> None:
        self.assertGreaterEqual(len(self.rust_schema), 80)
        self.assertIn('configure_provider', self.rust_schema)
        cfg = self.rust_schema['configure_provider']
        self.assertIn('deepseekApiKey', cfg.allowed_fields)
        self.assertIn('qwenWorkspaceId', cfg.allowed_fields)
        self.assertEqual([f.primary for f in cfg.required_fields], ['model'])
        rename = self.rust_schema['rename_record']
        self.assertEqual({f.primary for f in rename.required_fields}, {'recordId', 'title'})
        meta = self.rust_schema['sync_app_metadata']
        self.assertIn('supportsSystemAudio', meta.allowed_fields)
        self.assertEqual({f.primary for f in meta.required_fields}, {'version', 'build'})
        self.assertEqual(self.rust_schema['empty_trash'].allowed_fields, frozenset())
        self.assertEqual(self.rust_schema['request_quit'].allowed_fields, frozenset())

    def test_rust_parser_honors_serde_rename_alias_and_default(self) -> None:
        snippet = '''
        #[derive(Deserialize)]
        #[serde(tag = "type", rename_all = "snake_case", rename_all_fields = "camelCase", deny_unknown_fields)]
        pub(crate) enum HostIntent {
            #[serde(rename = "custom_cmd", alias = "legacy_cmd")]
            CustomCommand {
                #[serde(rename = "explicitKey", alias = "oldKey")]
                internal_field: String,
                #[serde(default)]
                defaulted_field: bool,
                optional_field: Option<String>,
                #[serde(skip)]
                ignored_field: u8,
            },
        }
        #[derive(Deserialize)]
        #[serde(tag = "type", rename_all = "snake_case", rename_all_fields = "camelCase", deny_unknown_fields)]
        pub(crate) enum AdapterEvent {
            Ping,
        }
        '''
        schema = parse_rust_command_schema(snippet)
        self.assertEqual(
            schema['custom_cmd'].allowed_fields,
            frozenset({'explicitKey', 'oldKey', 'defaultedField', 'optionalField'}),
        )
        self.assertEqual(
            [f.primary for f in schema['custom_cmd'].required_fields],
            ['explicitKey'],
        )
        assert_host_commands_match(
            schema,
            [EmittedCommand('AliasCall', 'legacy_cmd', frozenset({'oldKey'}))],
            'synthetic',
        )

    def test_swift_host_commands_match_rust_command_rs(self) -> None:
        emitted = parse_swift_emitted_commands(
            SWIFT_HOST_COMMAND.read_text(encoding='utf-8'), 'HostCommand'
        )
        self.assertGreaterEqual(len(emitted), 60)
        assert_host_commands_match(
            self.rust_schema, emitted, str(SWIFT_HOST_COMMAND.relative_to(REPO_ROOT))
        )

    def test_swift_adapter_events_match_rust_command_rs(self) -> None:
        emitted = parse_swift_emitted_commands(
            SWIFT_ADAPTER_EVENT.read_text(encoding='utf-8'), 'HostAdapterEvent'
        )
        self.assertGreaterEqual(len(emitted), 16)
        assert_host_commands_match(
            self.rust_schema, emitted, str(SWIFT_ADAPTER_EVENT.relative_to(REPO_ROOT))
        )

    def test_kotlin_host_commands_match_rust_command_rs(self) -> None:
        emitted = parse_kotlin_emitted_commands(
            KOTLIN_HOST_COMMAND.read_text(encoding='utf-8'), 'HostCommand'
        )
        self.assertGreaterEqual(len(emitted), 60)
        assert_host_commands_match(
            self.rust_schema, emitted, str(KOTLIN_HOST_COMMAND.relative_to(REPO_ROOT))
        )

    def test_kotlin_adapter_events_match_rust_command_rs(self) -> None:
        emitted = parse_kotlin_emitted_commands(
            KOTLIN_ADAPTER_EVENT.read_text(encoding='utf-8'), 'HostAdapterEvent'
        )
        self.assertGreaterEqual(len(emitted), 16)
        assert_host_commands_match(
            self.rust_schema, emitted, str(KOTLIN_ADAPTER_EVENT.relative_to(REPO_ROOT))
        )

    def test_rejects_missing_required_field_in_swift_and_kotlin(self) -> None:
        drifted_swift = '''
        public enum HostCommand: Encodable {
            case renameRecord(recordId: String)
            private enum CodingKeys: String, CodingKey { case type, recordId }
            public var commandType: String {
                switch self {
                case .renameRecord: "rename_record"
                }
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(commandType, forKey: .type)
                switch self {
                case let .renameRecord(recordId):
                    try c.encode(recordId, forKey: .recordId)
                }
            }
        }
        '''
        swift_emitted = parse_swift_emitted_commands(drifted_swift, 'HostCommand')
        with self.assertRaises(ValueError) as swift_ctx:
            assert_host_commands_match(self.rust_schema, swift_emitted, 'synthetic/HostCommand.swift')
        self.assertIn('missing required JSON field', str(swift_ctx.exception))
        self.assertIn("'title'", str(swift_ctx.exception))
        self.assertIn('rename_record', str(swift_ctx.exception))
        self.assertIn('synthetic/HostCommand.swift', str(swift_ctx.exception))

        drifted_kotlin = '''
        @Serializable
        sealed interface HostCommand {
            val commandType: String
                get() = when (this) {
                    is RenameRecord -> "rename_record"
                }
            @Serializable @SerialName("rename_record")
            data class RenameRecord(val recordId: String) : HostCommand
        }
        '''
        kotlin_emitted = parse_kotlin_emitted_commands(drifted_kotlin, 'HostCommand')
        with self.assertRaises(ValueError) as kotlin_ctx:
            assert_host_commands_match(
                self.rust_schema, kotlin_emitted, 'synthetic/HostCommandModels.kt'
            )
        self.assertIn('missing required JSON field', str(kotlin_ctx.exception))
        self.assertIn("'title'", str(kotlin_ctx.exception))
        self.assertIn('rename_record', str(kotlin_ctx.exception))
        self.assertIn('synthetic/HostCommandModels.kt', str(kotlin_ctx.exception))

    def test_rejects_synthetic_swift_unknown_tag(self) -> None:
        drifted_swift = '''
        public enum HostCommand: Encodable {
            case legacyPurgeAll
            private enum CodingKeys: String, CodingKey { case type }
            public var commandType: String {
                switch self {
                case .legacyPurgeAll: "legacy_purge_all"
                }
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(commandType, forKey: .type)
                switch self {
                case .legacyPurgeAll:
                    break
                }
            }
        }
        '''
        emitted = parse_swift_emitted_commands(drifted_swift, 'HostCommand')
        with self.assertRaises(ValueError) as ctx:
            assert_host_commands_match(self.rust_schema, emitted, 'synthetic/HostCommand.swift')
        message = str(ctx.exception)
        self.assertIn('legacy_purge_all', message)
        self.assertIn('synthetic/HostCommand.swift', message)
        self.assertIn('crates/koe-runtime/src/command.rs', message)

    def test_rejects_synthetic_swift_unknown_field(self) -> None:
        drifted_swift = '''
        public enum HostCommand: Encodable {
            case trashRecord(recordId: String)
            private enum CodingKeys: String, CodingKey { case type, recrodId }
            public var commandType: String {
                switch self {
                case .trashRecord: "trash_record"
                }
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(commandType, forKey: .type)
                switch self {
                case let .trashRecord(recordId):
                    try c.encode(recordId, forKey: .recrodId)
                }
            }
        }
        '''
        emitted = parse_swift_emitted_commands(drifted_swift, 'HostCommand')
        with self.assertRaises(ValueError) as ctx:
            assert_host_commands_match(self.rust_schema, emitted, 'synthetic/HostCommand.swift')
        message = str(ctx.exception)
        self.assertIn('recrodId', message)
        self.assertIn('trash_record', message)
        self.assertIn('synthetic/HostCommand.swift', message)
        self.assertIn('#[serde(deny_unknown_fields)]', message)

    def test_swift_multiline_coding_keys_qualified_key_where_union_multiliteral_and_default(
        self,
    ) -> None:
        multiline_and_qualified = '''
        public enum HostCommand: Encodable {
            case trashRecord(recordId: String)
            case renameRecord(recordId: String, title: String)
            case setRecordProject(recordId: String, project: String?)
            private enum CodingKeys: String, CodingKey {
                case type,
                     recordId,
                     driftedTitle = "renamedTitle",
                     bogusKey
            }
            public var commandType: String {
                switch self {
                case .trashRecord: "trash_record"
                case .renameRecord: "rename_record"
                case let .setRecordProject(_, p):
                    p == nil ? "set_record_project" : "set_record_project_v2"
                }
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(commandType, forKey: .type)
                switch self {
                case let .trashRecord(recordId) where recordId.isEmpty:
                    try c.encode(recordId, forKey: CodingKeys.bogusKey)
                case let .trashRecord(recordId):
                    try c.encode(recordId, forKey: .recordId)
                case let .renameRecord(recordId, title):
                    try c.encode(recordId, forKey: .recordId)
                    try c.encode(title, forKey: .driftedTitle)
                case let .setRecordProject(recordId, _):
                    try c.encode(recordId, forKey: .recordId)
                }
            }
        }
        '''
        emitted = parse_swift_emitted_commands(multiline_and_qualified, 'HostCommand')
        errors = validate_host_commands(self.rust_schema, emitted, 'synthetic/HostCommand.swift')
        joined = '\n'.join(errors)
        self.assertIn("'bogusKey'", joined)
        self.assertIn("'renamedTitle'", joined)
        self.assertIn('set_record_project_v2', joined)

        default_arm_swift = '''
        public enum HostCommand: Encodable {
            case back
            private enum CodingKeys: String, CodingKey { case type, extraKey }
            public var commandType: String {
                switch self {
                case .back: "back"
                }
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(commandType, forKey: .type)
                switch self {
                default:
                    try c.encode("x", forKey: .extraKey)
                }
            }
        }
        '''
        with self.assertRaises(ValueError) as default_ctx:
            parse_swift_emitted_commands(default_arm_swift, 'HostCommand')
        self.assertIn('default:', str(default_ctx.exception))
        self.assertIn('extraKey', str(default_ctx.exception))

    def test_rejects_synthetic_kotlin_unknown_tag(self) -> None:
        drifted_kotlin = '''
        @Serializable
        sealed interface HostCommand {
            val commandType: String
                get() = when (this) {
                    PhantomSync -> "phantom_sync"
                }
            @Serializable @SerialName("phantom_sync") data object PhantomSync : HostCommand
        }
        '''
        emitted = parse_kotlin_emitted_commands(drifted_kotlin, 'HostCommand')
        with self.assertRaises(ValueError) as ctx:
            assert_host_commands_match(self.rust_schema, emitted, 'synthetic/HostCommandModels.kt')
        message = str(ctx.exception)
        self.assertIn('phantom_sync', message)
        self.assertIn('synthetic/HostCommandModels.kt', message)
        self.assertIn('crates/koe-runtime/src/command.rs', message)

    def test_rejects_synthetic_kotlin_unknown_field(self) -> None:
        drifted_kotlin = '''
        @Serializable
        sealed interface HostCommand {
            val commandType: String
                get() = when (this) {
                    is CreateNote -> "create_note"
                }
            @Serializable @SerialName("create_note")
            data class CreateNote(val title: String, val text: String, val stayOnCurrentPage: Boolean = false) : HostCommand
        }
        '''
        emitted = parse_kotlin_emitted_commands(drifted_kotlin, 'HostCommand')
        with self.assertRaises(ValueError) as ctx:
            assert_host_commands_match(self.rust_schema, emitted, 'synthetic/HostCommandModels.kt')
        message = str(ctx.exception)
        self.assertIn('stayOnCurrentPage', message)
        self.assertIn('create_note', message)
        self.assertIn('synthetic/HostCommandModels.kt', message)
        self.assertIn('#[serde(deny_unknown_fields)]', message)

    def test_kotlin_missing_serial_name_visibility_top_level_and_annotated_ctor(self) -> None:
        missing_serial = '''
        @Serializable
        sealed interface HostCommand {
            val commandType: String
                get() = when (this) {
                    is TrashRecord -> "trash_record"
                }
            @Serializable
            public data class TrashRecord(val recordId: String) : HostCommand
        }
        '''
        with self.assertRaises(ValueError) as missing_ctx:
            parse_kotlin_emitted_commands(missing_serial, 'HostCommand')
        self.assertIn('HostCommand.TrashRecord', str(missing_ctx.exception))
        self.assertIn('@SerialName', str(missing_ctx.exception))

        visibility_top_level_and_ctor = '''
        @Serializable
        sealed interface HostCommand {
            val commandType: String
                get() = when (this) {
                    is TrashRecord -> "trash_record"
                    is TopLevelDrift -> "top_level_drift"
                }
            @Serializable @SerialName("trash_record")
            internal data class TrashRecord @Suppress("unused") constructor(
                val recordId: String,
                val bogusField: String,
            ) : HostCommand
        }

        @Serializable @SerialName("top_level_drift")
        public data class TopLevelDrift(val value: String) : HostCommand
        '''
        emitted = parse_kotlin_emitted_commands(visibility_top_level_and_ctor, 'HostCommand')
        errors = validate_host_commands(self.rust_schema, emitted, 'synthetic/HostCommandModels.kt')
        joined = '\n'.join(errors)
        self.assertIn("'bogusField'", joined)
        self.assertIn('trash_record', joined)
        self.assertIn('top_level_drift', joined)

        unparsed_when_arm = '''
        @Serializable
        sealed interface HostCommand {
            val commandType: String
                get() = when (this) {
                    Back -> "back"
                    GhostBranch -> "ghost_branch"
                }
            @Serializable @SerialName("back") data object Back : HostCommand
        }
        '''
        with self.assertRaises(ValueError) as when_ctx:
            parse_kotlin_emitted_commands(unparsed_when_arm, 'HostCommand')
        self.assertIn('GhostBranch', str(when_ctx.exception))
        self.assertIn('ghost_branch', str(when_ctx.exception))

    def test_rejects_synthetic_kotlin_serial_name_and_command_type_mismatch(self) -> None:
        drifted_kotlin = '''
        @Serializable
        sealed interface HostCommand {
            val commandType: String
                get() = when (this) {
                    EmptyTrash -> "empty_bin"
                }
            @Serializable @SerialName("empty_trash") data object EmptyTrash : HostCommand
        }
        '''
        with self.assertRaises(ValueError) as ctx:
            parse_kotlin_emitted_commands(drifted_kotlin, 'HostCommand')
        self.assertIn('empty_trash', str(ctx.exception))
        self.assertIn('empty_bin', str(ctx.exception))

    def test_rust_host_api_matches_c_header(self) -> None:
        rust_sources = collect_rust_host_api_sources(RUST_HOST_API_DIR)
        rust_abi = parse_rust_c_abi_surface(rust_sources)
        header_abi = parse_c_header_abi_surface(C_HOST_API_HEADER.read_text(encoding='utf-8'))
        self.assertEqual(len(rust_abi.functions), 16)
        self.assertEqual(set(rust_abi.structs), {'KoePcmReceipt', 'KoePlaybackReceipt', 'KoeOwnedBytes'})
        self.assertEqual(set(rust_abi.callbacks), {'KoeCredentialCallback'})
        assert_c_abi_parity(rust_abi, header_abi)

    def test_c_abi_scanner_covers_nested_rust_modules_and_stray_header_declarations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'lib.rs').write_text(
                '#[unsafe(no_mangle)]\npub extern "C" fn koe_root() -> u32 { 0 }\n',
                encoding='utf-8',
            )
            nested = root / 'ffi'
            nested.mkdir()
            (nested / 'extra.rs').write_text(
                '#[unsafe(no_mangle)]\npub extern "C" fn koe_nested() -> bool { true }\n',
                encoding='utf-8',
            )
            (nested / 'extra_tests.rs').write_text(
                '#[unsafe(no_mangle)]\npub extern "C" fn koe_ignored_suffix() {}\n',
                encoding='utf-8',
            )
            tests_dir = root / 'tests'
            tests_dir.mkdir()
            (tests_dir / 'fixture.rs').write_text(
                '#[unsafe(no_mangle)]\npub extern "C" fn koe_ignored_dir() {}\n',
                encoding='utf-8',
            )
            rust_abi = parse_rust_c_abi_surface(collect_rust_host_api_sources(root))
            self.assertEqual(set(rust_abi.functions), {'koe_root', 'koe_nested'})

        header_with_strays = parse_c_header_abi_surface(
            '''
            #ifndef TEST_H
            #define TEST_H
            void koe_before_extern(void);
            #ifdef __cplusplus
            extern "C" {
            #endif
            uint32_t koe_root(void);
            #ifdef __cplusplus
            }
            #endif
            bool koe_between_blocks(void);
            #ifdef __cplusplus
            extern "C" {
            #endif
            bool koe_nested(void);
            #ifdef __cplusplus
            }
            #endif
            void koe_after_extern(void);
            #endif
            '''
        )
        self.assertEqual(
            set(header_with_strays.functions),
            {
                'koe_before_extern',
                'koe_root',
                'koe_between_blocks',
                'koe_nested',
                'koe_after_extern',
            },
        )
        errors = validate_c_abi_parity(rust_abi, header_with_strays)
        joined = '\n'.join(errors)
        self.assertIn("'koe_before_extern'", joined)
        self.assertIn("'koe_between_blocks'", joined)
        self.assertIn("'koe_after_extern'", joined)

    def test_rust_c_abi_parser_handles_repr_c_modifiers_export_name_and_malformed_fields(
        self,
    ) -> None:
        rust_abi = parse_rust_c_abi_surface(
            [
                '''
                #[repr(C, align(8))]
                pub struct KoeAligned {
                    pub value: u64,
                }

                #[unsafe(export_name = "koe_aliased_v1")]
                pub extern "C" fn internal_impl(handle: u64) -> KoeAligned {
                    KoeAligned { value: handle }
                }

                #[export_name = "koe_legacy_alias"]
                extern "C" fn legacy_impl() -> u32 { 1 }
                '''
            ]
        )
        self.assertEqual(rust_abi.structs, {'KoeAligned': (('value', 'uint64_t'),)})
        self.assertEqual(set(rust_abi.functions), {'koe_aliased_v1', 'koe_legacy_alias'})
        self.assertEqual(
            rust_abi.functions['koe_aliased_v1'],
            CFunctionSignature(return_type='KoeAligned', param_types=('uint64_t',)),
        )

        with self.assertRaises(ValueError) as ctx:
            parse_rust_c_abi_surface(
                [
                    '''
                    #[repr(C)]
                    pub struct KoeBroken {
                        not_a_valid_field_decl
                    }
                    '''
                ]
            )
        self.assertIn('KoeBroken', str(ctx.exception))

    def test_c_abi_parity_rejects_drifted_functions_structs_and_callbacks(self) -> None:
        rust_abi = parse_rust_c_abi_surface(
            [
                '''
                pub type KoeCredentialCallback =
                    unsafe extern "C" fn(*mut c_void, u32, *const c_char) -> i32;

                #[repr(C)]
                pub struct KoeSample {
                    pub count: u64,
                    pub reserved: [u8; 4],
                }

                #[unsafe(no_mangle)]
                pub extern "C" fn koe_ping(handle: u64) -> bool { true }

                #[unsafe(no_mangle)]
                pub extern "C" fn koe_pong(handle: u64) -> u32 { 0 }

                #[unsafe(no_mangle)]
                pub unsafe extern "C" fn koe_only_in_rust(cb: Option<KoeCredentialCallback>) {}
                '''
            ]
        )
        drifted_header = parse_c_header_abi_surface(
            '''
            #ifndef TEST_H
            #define TEST_H
            #ifdef __cplusplus
            extern "C" {
            #endif
            typedef int64_t (*KoeCredentialCallback)(void *ctx, uint32_t op, const char *ref);
            typedef struct KoeSample {
                uint32_t count;
                uint8_t pad[4];
            } KoeSample;
            uint32_t koe_ping(uint64_t handle, bool extra);
            uint32_t koe_pong(uint32_t handle);
            void koe_only_in_header(void);
            #ifdef __cplusplus
            }
            #endif
            #endif
            '''
        )
        errors = validate_c_abi_parity(rust_abi, drifted_header)
        joined = '\n'.join(errors)
        self.assertIn("callback typedef 'KoeCredentialCallback' return type mismatch", joined)
        self.assertIn("struct 'KoeSample' layout mismatch", joined)
        self.assertIn("extern \"C\" function 'koe_ping' return type mismatch", joined)
        self.assertIn("extern \"C\" function 'koe_ping' parameter count mismatch", joined)
        self.assertIn("extern \"C\" function 'koe_pong' parameter types mismatch", joined)
        self.assertIn("Rust exports extern \"C\" function 'koe_only_in_rust'", joined)
        self.assertIn("koe_host_api.h declares extern \"C\" function 'koe_only_in_header'", joined)

    def test_command_size_limits_match_across_rust_bridge_and_jni(self) -> None:
        errors = validate_command_size_limits(
            RUST_RUNTIME_LIB_RS.read_text(encoding='utf-8'),
            RUST_LOCAL_BRIDGE_RS.read_text(encoding='utf-8'),
            ANDROID_CLIENT_JNI_CPP.read_text(encoding='utf-8'),
        )
        self.assertEqual(errors, [], '\n'.join(errors))

    def test_command_size_limits_reject_synthetic_drift(self) -> None:
        errors = validate_command_size_limits(
            'pub const MAX_COMMAND_JSON_BYTES: usize = 2 * 1024 * 1024;',
            'const MAX_LINE_BYTES: u64 = 1024 * 1024;',
            'constexpr size_t kMaxCommandJsonBytes = 4 * 1024 * 1024;',
        )
        joined = '\n'.join(errors)
        self.assertIn('MAX_LINE_BYTES', joined)
        self.assertIn('kMaxCommandJsonBytes', joined)

    def test_no_client_chinese_record_status_checks(self) -> None:
        source_files: list[tuple[str, str]] = []
        for directory in CLIENT_STATUS_CHECK_DIRS:
            for ext in ('*.swift', '*.kt'):
                for path in sorted(directory.rglob(ext)):
                    source_files.append(
                        (str(path.relative_to(REPO_ROOT)), path.read_text(encoding='utf-8'))
                    )
        self.assertGreaterEqual(len(source_files), 40)
        violations = find_client_chinese_status_checks(source_files)
        self.assertEqual(violations, [], '\n'.join(violations))

    def test_client_chinese_record_status_check_rejects_synthetic_literals(self) -> None:
        synthetic = find_client_chinese_status_checks(
            [
                (
                    'synthetic/Record.swift',
                    '// "转写中" in comment is ignored\nlet x = status == "转写中" || status == "等待转写"\n',
                ),
                (
                    'synthetic/Record.kt',
                    'val canTrash = status != "整理中"\n',
                ),
            ]
        )
        self.assertEqual(len(synthetic), 3)


if __name__ == '__main__':
    unittest.main()
