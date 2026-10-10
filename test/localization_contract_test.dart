import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/core/native_ui_catalog.dart';
import 'package:getbible/core/ui_strings.dart';
import 'package:getbible/core/web_ui_catalog.dart';

import '../tool/sync_web_locales.dart' as reference_locales;

Map<String, Object?> _object(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>);

List<String> _placeholders(String value) => (RegExp(
  r'\{([a-zA-Z][a-zA-Z0-9]*)\}',
).allMatches(value).map((match) => match.group(1)!).toList()..sort());

void main() {
  test(
    'reference keys, ordering, packs and variables are one pinned contract',
    () {
      final contract = _object('test/fixtures/ui_locale_contract.json');
      expect(
        contract['source'],
        'https://github.com/getbible/app.getbible.life',
      );
      expect(contract['revision'], matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(contract['messageKeys'], orderedEquals(webUiMessages.keys));
      expect(contract['nativeProductCopyKeys'], ['clearAllConfirm']);
      expect(contract['locales'], orderedEquals(webUiLocales));
      final supported =
          (jsonDecode(File('assets/locales/index.json').readAsStringSync())
                  as List)
              .cast<String>();
      expect(supported, orderedEquals(webUiLocales));
      expect(supported, hasLength(69));
      final english = webUiMessages.values.toList();
      final fallbacks = <String>[];
      for (final locale in supported) {
        final messages =
            (jsonDecode(File('assets/locales/$locale.json').readAsStringSync())
                    as List)
                .cast<String>();
        expect(messages, hasLength(english.length), reason: locale);
        if (messages.every((message) => message.isEmpty)) {
          fallbacks.add(locale);
        }
        for (var index = 0; index < messages.length; index++) {
          if (messages[index].isEmpty) {
            continue; // Upstream's explicit per-message fallback.
          }
          expect(
            _placeholders(messages[index]),
            _placeholders(english[index]),
            reason: '$locale/${webUiMessages.keys.elementAt(index)}',
          );
        }
        if (locale == 'en') {
          for (var index = 0; index < messages.length; index++) {
            expect(
              messages[index].isEmpty || messages[index] == english[index],
              isTrue,
            );
          }
        }
      }
      expect(fallbacks, orderedEquals(webUiFallbackLocales));
    },
  );

  test('reference synchronization keeps native branding and external keys', () {
    for (final suffix in ['Life', 'live']) {
      expect(
        reference_locales.adaptReferenceMessage(
          'clearAllConfirm',
          'Clear all local getBible.$suffix data?',
        ),
        'Clear all local getBible data?',
      );
    }
    expect(
      reference_locales.adaptReferenceMessage(
        'clearAllConfirm',
        'Clear all local Get Bible data?',
      ),
      'Clear all local getBible data?',
    );
    const source = 'https://app.getbible.life';
    expect(reference_locales.adaptReferenceMessage('source', source), source);
  });

  test(
    'every native pack covers all explicit UI templates with intact variables',
    () {
      final english = _object(
        'assets/native_locales/en.json',
      ).cast<String, String>();
      expect(nativeUiKeys, {
        for (final entry in english.entries) entry.value: entry.key,
      });
      final provenance = _object('assets/native_locales/provenance.json');
      expect(provenance['sourceMessages'], english);
      final protectedTerms = (provenance['protectedTerms']! as List)
          .cast<String>();
      final invariantMessages = (provenance['invariantMessages']! as List)
          .cast<String>();
      final locales = provenance['locales']! as Map<String, Object?>;
      expect(locales.keys.toSet(), UiStrings.supportedLocales.toSet());
      for (final locale in UiStrings.supportedLocales) {
        final translated = _object(
          'assets/native_locales/$locale.json',
        ).cast<String, String>();
        expect(translated.keys.toSet(), english.keys.toSet(), reason: locale);
        for (final entry in translated.entries) {
          if (invariantMessages.contains(english[entry.key])) {
            expect(
              entry.value,
              english[entry.key],
              reason: '$locale/${entry.key}',
            );
          }
          expect(
            RegExp(
              r'get\s*bible',
              caseSensitive: false,
            ).allMatches(entry.value).every((match) => match[0] == 'getBible'),
            isTrue,
            reason: '$locale/${entry.key} preserves exact product spelling',
          );
          expect(
            entry.value.trim(),
            isNotEmpty,
            reason: '$locale/${entry.key}',
          );
          expect(
            _placeholders(entry.value),
            _placeholders(english[entry.key]!),
            reason: '$locale/${entry.key}',
          );
          expect(
            entry.value,
            isNot(
              matches(
                RegExp(
                  r'GB\s*PH\s*\d+\s*GB|@\s*@\s*GB\s*\d+',
                  caseSensitive: false,
                ),
              ),
            ),
            reason: '$locale/${entry.key}',
          );
          for (final term in protectedTerms) {
            expect(
              entry.value.split(term).length,
              greaterThanOrEqualTo(english[entry.key]!.split(term).length),
              reason: '$locale/${entry.key} must preserve $term',
            );
          }
        }
        final metadata = locales[locale]! as Map<String, Object?>;
        final pending = (metadata['englishFallbackKeys'] as List? ?? [])
            .cast<String>();
        expect(pending.toSet(), hasLength(pending.length), reason: locale);
        for (final key in pending) {
          expect(english, contains(key), reason: '$locale/$key');
          expect(translated[key], english[key], reason: '$locale/$key');
        }
        if (pending.isNotEmpty) {
          expect(metadata['status'], contains('English fallback'));
          expect(metadata['status'], contains('human review pending'));
        }
        expect(
          metadata['target'] == 'en',
          webUiFallbackLocales.contains(locale),
          reason: '$locale must follow the reference fallback policy',
        );
        if (metadata['target'] == 'en') {
          expect(
            translated,
            english,
            reason: '$locale follows reference English fallback policy',
          );
        } else {
          expect(
            translated.values.where((value) => !english.values.contains(value)),
            isNotEmpty,
            reason:
                '$locale cannot silently claim a translated English-only pack',
          );
          expect(metadata['status'], contains('human review pending'));
        }
      }
    },
  );
}
