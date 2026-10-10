#!/usr/bin/env python3
"""Build deterministic native UI message catalogs, without network access.

Only explicit UiStrings.text literal templates and registered UI label defaults
are collected. Scripture, names, user content and API metadata are excluded.
Run after editing UI strings; pass --check in CI to detect catalog drift.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MESSAGE = re.compile(r"(?:UiStrings\.of\([^)]*\)|strings|ui)\.text\(\s*(['\"])")
STATIC_CONTROL = re.compile(
    r"(?:\b(?:Text|SelectableText)\(\s*|"
    r"\b(?:tooltip|semanticLabel|labelText|hintText|helperText):\s*)(['\"])"
)
UNTRANSLATED_BRANDS = {'GetBible API'}


def read_literal(source: str, offset: int) -> tuple[str, int]:
    """Read a Dart literal; interpolation must be passed as named variables."""
    quote = source[offset]
    result = []
    cursor = offset + 1
    while cursor < len(source):
        char = source[cursor]
        if char == quote:
            return ''.join(result), cursor + 1
        if char == '\\':
            cursor += 1
            char = source[cursor]
            if char == 'u':
                digits = source[cursor + 1:cursor + 5]
                if not re.fullmatch('[0-9a-fA-F]{4}', digits):
                    raise ValueError('Use literal Unicode in UI templates.')
                result.append(chr(int(digits, 16)))
                cursor += 5
                continue
            result.append({'n': '\n', 'r': '\r', 't': '\t'}.get(char, char))
        elif char == '$':
            raise ValueError('UI templates must use {named} variables, not Dart interpolation.')
        else:
            result.append(char)
        cursor += 1
    raise ValueError('Unterminated UI template')


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False).replace('$', r'\$')


def dart_catalog(source: str, name: str = 'nativeUiKeys') -> dict[str, str]:
    """Compare generated map contents independently of dart format wrapping."""
    body = source.split(f'{name} = <String, String>{{', 1)[1].rsplit('};', 1)[0]
    values = {}
    cursor = 0
    while cursor < len(body):
        while cursor < len(body) and body[cursor].isspace():
            cursor += 1
        if cursor == len(body):
            break
        literal, cursor = read_literal(body, cursor)
        while body[cursor].isspace():
            cursor += 1
        if body[cursor] != ':':
            raise ValueError('Invalid generated native catalog')
        cursor += 1
        while body[cursor].isspace():
            cursor += 1
        key, cursor = read_literal(body, cursor)
        while body[cursor].isspace():
            cursor += 1
        if body[cursor] != ',':
            raise ValueError('Invalid generated native catalog')
        cursor += 1
        values[literal] = key
    return values


def inventory() -> dict[str, str]:
    # The keyed catalog is authoritative; the reference English pack is empty.
    web = set(dart_catalog((ROOT / 'lib/core/web_ui_catalog.dart').read_text(encoding='utf-8'), 'webUiMessages').values())
    values = set()
    for path in sorted((ROOT / 'lib').rglob('*.dart')):
        if path.name in {'ui_strings.dart', 'native_ui_catalog.dart'}:
            continue
        text = path.read_text(encoding='utf-8')
        for match in MESSAGE.finditer(text):
            value, end = read_literal(text, match.end() - 1)
            while adjacent := re.match(r"\s*(['\"])", text[end:]):
                next_value, end = read_literal(text, end + adjacent.end() - 1)
                value += next_value
            values.add(value)
    # Explicit defaults are an application-owned UI boundary, not public data.
    defaults = ROOT / 'tool/native_ui_defaults.json'
    if defaults.exists():
        values.update(json.loads(defaults.read_text(encoding='utf-8')))
    messages = {}
    for value in sorted(values - web):
        words = re.findall(r'[A-Za-z0-9]+', value)
        words = words[:9] or ['message']
        key = 'native.' + words[0].lower() + ''.join(w[:1].upper() + w[1:] for w in words[1:])
        if key in messages:
            key += hashlib.sha256(value.encode()).hexdigest()[:8]
        messages[key] = value
    return dict(sorted(messages.items()))


def audit_static_controls() -> None:
    """Catch newly added English controls before they bypass the inventory.

    Dynamic source/user text is deliberately excluded; those boundaries still
    require code review. Brand names are the only allowed plain static labels.
    """
    missing = []
    for path in sorted((ROOT / 'lib/presentation').rglob('*.dart')):
        source = path.read_text(encoding='utf-8')
        for match in STATIC_CONTROL.finditer(source):
            try:
                value, _ = read_literal(source, match.end() - 1)
            except ValueError:
                continue  # Dynamic source metadata is not a UI template.
            if value.strip() and value not in UNTRANSLATED_BRANDS:
                line = source[:match.start()].count('\n') + 1
                missing.append(f'{path.relative_to(ROOT)}:{line}: {value}')
    if missing:
        raise ValueError('Localize new static controls explicitly:\n' + '\n'.join(missing))


def generate(check: bool = False) -> None:
    audit_static_controls()
    messages = inventory()
    outputs = {
        'assets/native_locales/en.json': json.dumps(messages, ensure_ascii=False, indent=2) + '\n',
        'lib/core/native_ui_catalog.dart': (
            '// Generated by tool/ui_locale_inventory.py. Do not edit by hand.\n'
            '// Explicit native UI extensions; Scripture and user text are excluded.\n\n'
            'const Map<String, String> nativeUiKeys = <String, String>{\n'
            + ''.join(f'  {quoted(value)}: {quoted(key)},\n' for key, value in messages.items())
            + '};\n'
        ),
    }
    changed = []
    for name, content in outputs.items():
        path = ROOT / name
        if path.exists() and path.read_text(encoding='utf-8') == content:
            continue
        if name.endswith('.dart') and path.exists():
            try:
                if dart_catalog(path.read_text(encoding='utf-8')) == dart_catalog(content):
                    continue
            except (IndexError, ValueError):
                pass
        changed.append(name)
        if not check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
    if check and changed:
        raise SystemExit('Run python3 tool/ui_locale_inventory.py: ' + ', '.join(changed))
    print(f'{len(messages)} native UI templates; {len(changed)} files updated.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    generate(parser.parse_args().check)
