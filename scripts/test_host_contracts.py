#!/usr/bin/env python3
from pathlib import Path
import re
from typing import NamedTuple
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
RUST_COMMAND_RS = REPO_ROOT / 'crates/koe-runtime/src/command.rs'
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


if __name__ == '__main__':
    unittest.main()
