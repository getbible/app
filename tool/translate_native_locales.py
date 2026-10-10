#!/usr/bin/env python3
"""Regenerate checked-in native UI translations using the reference app policy.

Network access is OPT IN: python3 tool/translate_native_locales.py --write
Only the static, public assets/native_locales/en.json catalog is submitted.
Never pass Scripture, API resource bodies, user text, backups or credentials.
Normal application builds/tests/runtime never invoke this tool or the service.
Generated text is machine translated and requires human linguistic review.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import http.cookiejar
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / 'assets/native_locales'
CACHE = ROOT / 'build/ui-translations'
URL = 'https://www.bing.com/translator'
USER_AGENT = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              'Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0')
ALIASES = {'enm': 'en', 'hbo': 'he', 'grc': 'el', 'cu': 'ru', 'cop': 'ar',
           'got': 'de', 'mlf': 'ml', 'rmq': 'es', 'mn': 'mn-Cyrl', 'nd': 'zu',
           'nn': 'nb', 'sr': 'sr-Cyrl', 'syr': 'ar', 'tl': 'fil', 'tsg': 'fil',
           'tlh': 'tlh-Latn', 'ppk': 'id', 'zh': 'zh-Hans'}
FALLBACKS = {'ch', 'chr', 'br', 'eo', 'gd', 'gv', 'la', 'pon', 'pot', 'tpi'}
TERMS = ['getBible.Life', 'GetBible', 'getBible', 'CrossWire', 'SWORD',
         'Markdown', 'SHA-256', 'SHA-1', 'SHA', 'UTF-8', 'JSON', 'MiB', 'KiB',
         'Ctrl', 'Strong’s', 'Strong\'s', '.md']
PLACEHOLDERS = re.compile(r'\{([a-zA-Z][a-zA-Z0-9]*)\}')


def reference_target(locale):
    # The actual pinned reference packs are authoritative. Some languages are
    # intentionally English fallbacks even beyond the generator's alias list.
    messages = read_json(ROOT / f'assets/locales/{locale}.json', [])
    if locale in FALLBACKS or not any(messages):
        return 'en'
    return ALIASES.get(locale, locale)


def placeholders(value):
    return sorted(PLACEHOLDERS.findall(value))


def protect(value):
    replacements = []
    def token(match):
        original = match.group() if hasattr(match, 'group') else match
        marker = f'GBPH{len(replacements):03}GB'
        replacements.append((marker, original))
        return marker
    protected = PLACEHOLDERS.sub(token, value)
    for term in TERMS:
        protected = protected.replace(term, token(term)) if term in protected else protected
    return protected, replacements


def valid_translation(original, value):
    return (bool(value) and placeholders(value) == placeholders(original)
            and not re.search(r'GB\s*PH\s*\d+\s*GB|@\s*@\s*GB\s*\d+', value, re.I)
            and all(value.count(term) >= original.count(term) for term in TERMS))


def restore_translation(original, protected, replacements, candidate):
    for token, original_token in replacements:
        if candidate.count(token) != protected.count(token):
            raise ValueError('The translation dropped or changed a protected term.')
        candidate = candidate.replace(token, original_token)
    if not valid_translation(original, candidate):
        raise ValueError('The translation changed a protected term or placeholder.')
    return candidate.strip()


class PublicTranslator:
    """Same ordinary public-page session used by the reference generator."""
    def __init__(self):
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        html = self.opener.open(urllib.request.Request(URL, headers={
            'User-Agent': USER_AGENT}), timeout=30).read().decode()
        self.ig = re.search(r'IG:"([^"]+)"', html).group(1)
        self.iid = re.search(r'data-iid="([^"]+)"', html).group(1)
        data = re.search(r'params_AbusePreventionHelper\s?=\s?([^\]]+\])', html)
        self.key, self.token, *_ = json.loads(data.group(1))
        self.sequence = 0

    def translate(self, text, target):
        self.sequence += 1
        endpoint = 'https://www.bing.com/ttranslatev3?' + urllib.parse.urlencode({
            'isVertical': '1', 'IG': self.ig, 'IID': self.iid,
            'SFX': str(self.sequence), 'ref': 'TThis', 'edgepdftranslator': '1'})
        body = urllib.parse.urlencode({'fromLang': 'en', 'to': target,
            'text': text, 'token': self.token, 'key': self.key,
            'tryFetchingGenderDebiasedTranslations': 'true'}).encode()
        request = urllib.request.Request(endpoint, data=body, headers={
            'User-Agent': USER_AGENT, 'Referer': URL,
            'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'})
        with self.opener.open(request, timeout=45) as response:
            result = json.load(response)
        if not isinstance(result, list) or not result:
            status = result.get('statusCode', 'invalid response') if isinstance(result, dict) else 'invalid response'
            if str(status) in {'401', '403', '429'}:
                # Some ordinary public-page responses report their HTTP-style
                # status in JSON. Respect those denials just like HTTP errors.
                raise urllib.error.HTTPError(endpoint, int(status),
                                             'Public translation unavailable', {}, None)
            raise ValueError(f'Public translation service returned {status} for {target}.')
        return result[0]['translations'][0]['text']


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def read_json(path, default):
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else default


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Explicitly submit public UI templates and write packs.')
    parser.add_argument('--workers', type=int, choices=range(1, 5), default=2, help='At most four independent public translation sessions.')
    parser.add_argument('--locales', help='Comma-separated supported UI locale codes; default all.')
    args = parser.parse_args()
    english = read_json(DIRECTORY / 'en.json', {})
    supported = read_json(ROOT / 'assets/locales/index.json', [])
    locales = args.locales.split(',') if args.locales else supported
    if set(locales) - set(supported):
        parser.error('Every requested locale must be in assets/locales/index.json.')
    if not args.write:
        print(f'{len(english)} public UI templates, {len(locales)} requested locales. Pass --write to translate.')
        return
    prior = read_json(DIRECTORY / 'provenance.json', {})
    previous_sources = prior.get('sourceMessages', {})
    targets = sorted({reference_target(locale) for locale in locales})
    lock = threading.Lock()
    generated = {}
    failures = []

    def worker(target):
        matching = [code for code in locales if reference_target(code) == target]
        if target == 'en':
            values = english
        else:
            values = {}
            checkpoint = read_json(CACHE / f'{target}.json', {})
            for key, original in english.items():
                cached = checkpoint.get(hashlib.sha256(original.encode()).hexdigest())
                if cached and valid_translation(original, cached):
                    values[key] = cached
            for code in matching:
                pack = read_json(DIRECTORY / f'{code}.json', {})
                values.update({key: value for key, value in pack.items()
                    if key in english and previous_sources.get(key) == english[key]
                    and valid_translation(english[key], value)})
            missing = [(key, value) for key, value in english.items() if key not in values]
            client = PublicTranslator() if missing else None
            chunks = []
            chunk = []
            size = 0
            for index, (key, value) in enumerate(missing):
                protected, replacements = protect(value)
                entry = (key, value, protected, replacements, f'@@GB{index:04}@@')
                if chunk and size + len(protected) + 20 > 2200:
                    chunks.append(chunk); chunk = []; size = 0
                chunk.append(entry); size += len(protected) + 20
            if chunk:
                chunks.append(chunk)
            for number, chunk in enumerate(chunks):
                with lock:
                    print(f'{target}: requesting batch {number + 1}/{len(chunks)} '
                          f'({len(chunk)} templates)', flush=True)
                text = '\n'.join(marker + '\n' + protected for _, _, protected, _, marker in chunk)
                translated = None
                for attempt in range(3):
                    try:
                        translated = client.translate(text, target)
                        break
                    except (OSError, ValueError, KeyError, IndexError) as error:
                        # Never bypass authorization or retry an access denial.
                        if isinstance(error, urllib.error.HTTPError) and error.code in {401, 403}:
                            raise RuntimeError(f'{target}: public service denied access ({error.code})') from error
                        if isinstance(error, urllib.error.HTTPError) and error.code == 429:
                            raise RuntimeError(f'{target}: public service rate limit; retry later') from error
                        if attempt == 2:
                            raise
                        with lock:
                            print(f'{target}: transient request failure ({error}); '
                                  f'retrying in {2 ** attempt}s', flush=True)
                        time.sleep(2 ** attempt)
                for position, (key, original, protected, replacements, marker) in enumerate(chunk):
                    next_marker = chunk[position + 1][4] if position + 1 < len(chunk) else None
                    start = translated.find(marker)
                    end = translated.find(next_marker, start + len(marker)) if next_marker else len(translated)
                    candidate = translated[start + len(marker):end].strip() if start >= 0 and end >= 0 else ''
                    try:
                        value = restore_translation(original, protected, replacements, candidate)
                    except ValueError:
                        # A public UI phrase may be dropped in a batch. Retry it
                        # independently, never silently replacing it with English.
                        value = None
                        for repair in range(2):
                            candidate = client.translate(protected, target)
                            try:
                                value = restore_translation(original, protected, replacements, candidate)
                                break
                            except ValueError:
                                continue
                        if value is None:
                            raise ValueError(f'{target}: invalid protected token/placeholder in {key}')
                    values[key] = value
                    checkpoint[hashlib.sha256(original.encode()).hexdigest()] = value
                CACHE.mkdir(parents=True, exist_ok=True)
                atomic_json(CACHE / f'{target}.json', checkpoint)
                with lock:
                    print(f'{target}: {number + 1}/{len(chunks)} batches', flush=True)
            if set(values) != set(english):
                raise ValueError(f'{target}: incomplete catalog')
        for code in matching:
            atomic_json(DIRECTORY / f'{code}.json', {key: values[key] for key in english})
        return target, matching

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(worker, target): target for target in targets}
        for future in concurrent.futures.as_completed(jobs):
            target = jobs[future]
            try:
                _, matching = future.result()
                generated.update({code: target for code in matching})
            except Exception as error:
                failures.append(str(error))
                print(f'FAILED {target}: {error}', flush=True)
    prior_status = prior.get('locales', {})
    prior_status.update({code: {'target': target,
        'status': 'reference English fallback' if target == 'en' and code != 'en' else 'source English' if code == 'en' else 'machine translated; human review pending'}
        for code, target in generated.items()})
    atomic_json(DIRECTORY / 'provenance.json', {
        'referencePolicy': 'getbible/app.getbible.life/scripts/generate-ui-locales.mjs',
        'provider': URL,
        'review': 'Machine-generated public UI only; no claim of human linguistic review.',
        'protectedTerms': TERMS,
        'sourceMessages': english,
        'locales': prior_status,
    })
    print(f'Wrote {len(generated)} complete native locale packs.')
    if failures:
        raise SystemExit('\n'.join(failures))


if __name__ == '__main__':
    main()
