#!/usr/bin/env python3
"""Check repository Markdown links and references to retired code."""
from bisect import bisect_right
from pathlib import Path
import re
import string
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
ACTIVE_DOCS = (
    'docs/ARCHITECTURE.md',
    'docs/material-pack.md',
    'docs/mode-workspaces.md',
)
RETIRED_SYMBOLS = (
    'KoeAppleShared',
    'tests/fixtures/flutter',
    'legacy_restore',
    'crates/koe-runtime/src/legacy.rs',
)
ARCHIVE_NOTE = re.compile(r'已(?:移除|归档)|\b(?:removed|archived)\b', re.IGNORECASE)
SENTENCE_END = re.compile(r'[。！？；;]|(?<=[.!?])\s+')
GIT_OBJECT = re.compile(r'[\da-f]{7,40}(?:\^\d*|~\d*)*:', re.IGNORECASE)
FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})')
CODE_SPAN = re.compile(r'(?<!`)(`+)(?!`)(?:(?!\n\s*\n)[\s\S])*?(?<!`)\1(?!`)')
BRACKET = re.compile(r'\\[^\n]|\[|\]')
ANGLE_DESTINATION = re.compile(r'<((?:\\[^\n]|[^<>\n\\])*)>')
LINK_END = re.compile(r"""(?:\s+(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\((?:\\.|[^()\\])*\)))?\s*\)""")
MARKDOWN_ESCAPE = re.compile(r'\\([' + re.escape(string.punctuation) + '])')


def prose_for_links(markdown):
    """Blank code examples while preserving character offsets."""
    lines = []
    fence = ''
    for line in markdown.splitlines(keepends=True):
        marker = FENCE.match(line)
        if fence:
            if marker and marker[1].startswith(fence) and not line[marker.end():].strip():
                fence = ''
        elif marker:
            fence = marker[1]
        else:
            lines.append(line)
            continue
        lines.append(re.sub(r'[^\r\n]', ' ', line))
    return CODE_SPAN.sub(lambda match: re.sub(r'[^\r\n]', ' ', match[0]), ''.join(lines))


def destination(markdown, start):
    while start < len(markdown) and markdown[start].isspace():
        start += 1
    angle = ANGLE_DESTINATION.match(markdown, start)
    if angle:
        return angle[1], LINK_END.match(markdown, angle.end())

    end = start
    depth = 0
    while end < len(markdown):
        char = markdown[end]
        if MARKDOWN_ESCAPE.match(markdown, end):
            end += 2
            continue
        if char.isspace() or (char == ')' and depth == 0):
            break
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
        end += 1
    if depth:
        return '', None
    return markdown[start:end], LINK_END.match(markdown, end)


def links(markdown):
    prose = prose_for_links(markdown)
    line_starts = [0, *(match.end() for match in re.finditer('\n', markdown))]
    labels = []
    consumed = 0
    previous = 0
    for token in BRACKET.finditer(prose):
        offset = token.start()
        if offset < consumed:
            continue
        if re.search(r'\n[^\S\n]*\n', prose[previous:offset]):
            labels.clear()
        previous = token.end()
        if token[0] == '[':
            labels.append(offset)
        elif token[0] == ']' and labels:
            label = labels.pop()
            if prose.startswith('(', token.end()):
                target, close = destination(prose, token.end() + 1)
                if close:
                    consumed = previous = close.end()
                    yield bisect_right(line_starts, label), target


def local_path(target):
    target = MARKDOWN_ESCAPE.sub(r'\1', target)
    if GIT_OBJECT.match(target) or target.lower().startswith(('http://', 'https://', 'mailto:')):
        return ''
    return unquote(urlsplit(target).path)


def active(relative):
    return len(relative.parts) == 1 or relative.as_posix() in ACTIVE_DOCS or (
        relative.parent.as_posix() == 'docs/agents'
    )


def check(root):
    root = root.resolve()
    problems = []
    documents = sorted({*root.glob('*.md'), *root.glob('docs/**/*.md'), *root.glob('.github/*.md')})
    for document in documents:
        relative = document.relative_to(root)
        markdown = document.read_text(encoding='utf-8')
        for line, target in links(markdown):
            path = local_path(target)
            if not path:
                continue
            resolved = (document.parent / path).resolve()
            if not resolved.is_relative_to(root):
                problems.append(f'{relative}:{line}: link leaves repository: {target}')
            elif not resolved.exists():
                problems.append(f'{relative}:{line}: broken link: {target}')
        if active(relative):
            for line, content in enumerate(markdown.splitlines(), 1):
                for sentence in SENTENCE_END.split(content):
                    if ARCHIVE_NOTE.search(sentence):
                        continue
                    for symbol in RETIRED_SYMBOLS:
                        if symbol in sentence:
                            problems.append(f'{relative}:{line}: retired symbol: {symbol}')
    return problems


def main():
    problems = check(ROOT)
    if problems:
        print('\n'.join(problems), file=sys.stderr)
        return 1
    print('check_docs: repository Markdown links and active symbols passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
