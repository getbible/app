import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/core/native_ui_catalog.dart';
import 'package:getbible/core/ui_strings.dart';
import 'package:getbible/core/web_ui_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'normalizes aliases, regional locales and unsupported source languages',
    () {
      expect(UiStrings.normalizeLocale('zh_CN'), 'zh-Hans');
      expect(UiStrings.normalizeLocale('zh-tw'), 'zh-Hant');
      expect(UiStrings.normalizeLocale('ZH-hANs'), 'zh-Hans');
      expect(UiStrings.normalizeLocale('zh-Hant-HK'), 'zh-Hant');
      expect(UiStrings.normalizeLocale('zh_HK'), 'zh-Hant');
      expect(UiStrings.normalizeLocale('zh-Hans-HK'), 'zh-Hans');
      expect(UiStrings.normalizeLocale(' pt_BR '), 'pt');
      expect(UiStrings.normalizeLocale('EN-us'), 'en');
      expect(UiStrings.normalizeLocale('enm'), 'enm');
      expect(UiStrings.normalizeLocale('unknown'), 'en');
      expect(UiStrings.normalizeLocale(null), 'en');
    },
  );

  test('English catalog covers every current reference key', () {
    for (final entry in webUiMessages.entries) {
      expect(UiStrings.english(entry.key), entry.value);
      expect(UiStrings.english.text(entry.value), entry.value);
    }
    expect(UiStrings.english('unknown'), 'unknown');
    expect(UiStrings.english.containsTemplate('Copy'), isTrue);
    expect(UiStrings.english.containsTemplate('Private diagnostic'), isFalse);
    for (final entry in nativeUiKeys.entries) {
      expect(UiStrings.english(entry.value), entry.key);
    }
  });

  test('RTL controls follow locale independently of Scripture direction', () {
    for (final locale in <String>['ar', 'cop', 'he', 'hbo', 'prs', 'syr']) {
      expect(UiStrings(locale, const []).isRtl, isTrue, reason: locale);
    }
    for (final locale in <String>['en', 'af', 'grc', 'zh-Hant']) {
      expect(UiStrings(locale, const []).isRtl, isFalse, reason: locale);
    }
    expect(const UiStrings('zh-Hant', []).flutterLocale.scriptCode, 'Hant');
    expect(const UiStrings('prs', []).flutterLocale.languageCode, 'fa');
    expect(const UiStrings('hbo', []).flutterLocale.languageCode, 'he');
    expect(const UiStrings('enm', []).flutterLocale.languageCode, 'en');
  });

  test('interpolation is one pass and leaves missing variables visible', () {
    expect(
      UiStrings.english('searchTranslation', {'translation': '{count}'}),
      'Search {count}',
    );
    expect(UiStrings.english('searchTranslation'), 'Search {translation}');
    expect(
      UiStrings.english.text('Uncatalogued public UI {count}', {'count': 2}),
      'Uncatalogued public UI 2',
    );
  });

  test(
    'invalid translated placeholders fall back without losing parameters',
    () {
      final List<String> messages = webUiMessages.values.toList();
      messages[webUiMessages.keys.toList().indexOf('searchTranslation')] =
          'Rechercher {wrong}';
      final strings = UiStrings('fr', messages);
      expect(
        strings('searchTranslation', {'translation': 'KJV'}),
        'Search KJV',
      );
      messages[webUiMessages.keys.toList().indexOf('searchTranslation')] =
          'Rechercher {translation}';
      expect(
        strings('searchTranslation', {'translation': 'KJV'}),
        'Rechercher KJV',
      );
    },
  );

  test(
    'native extensions reject malformed placeholders and never translate user text',
    () {
      final entry = nativeUiKeys.entries.firstWhere(
        (entry) => entry.key.contains('{'),
      );
      final strings = UiStrings('af', const [], {
        entry.value: 'Verkeerde {missing}',
      });
      expect(strings.text(entry.key), entry.key);
      expect(
        strings.text('A private notebook name'),
        'A private notebook name',
      );
    },
  );

  test('missing/malformed packs fall back independently', () async {
    final key = nativeUiKeys['Complete private backup']!;
    final bundle = _Bundle({
      'assets/locales/af.json': '{"unexpected":true}',
      'assets/native_locales/af.json': jsonEncode({
        key: 'Volledige privaat rugsteun',
      }),
    });
    final strings = await UiStrings.load('af-ZA', bundle: bundle);
    expect(strings('copy'), 'Copy');
    expect(
      strings.text('Complete private backup'),
      'Volledige privaat rugsteun',
    );
    expect((await UiStrings.load('he', bundle: bundle))('copy'), 'Copy');
  });

  testWidgets(
    'scope localizes pushed routes and updates controls without altering source text',
    (tester) async {
      final af = (await tester.runAsync(() => UiStrings.load('af')))!;
      final ar = (await tester.runAsync(() => UiStrings.load('ar')))!;
      final notifier = ValueNotifier<UiStrings>(af);
      addTearDown(notifier.dispose);
      const String scripture = 'בְּרֵאשִׁית — In the beginning';
      await tester.pumpWidget(
        ValueListenableBuilder<UiStrings>(
          valueListenable: notifier,
          builder: (context, strings, _) => MaterialApp(
            builder: (context, child) => UiStringsScope(
              strings: strings,
              child: Directionality(
                textDirection: strings.isRtl
                    ? TextDirection.rtl
                    : TextDirection.ltr,
                child: child!,
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(UiStrings.of(context)('copy')),
                          const Text(scripture),
                        ],
                      ),
                    ),
                  ),
                  child: Text(UiStrings.of(context)('study')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(af('study')));
      await tester.pumpAndSettle();
      expect(find.text(af('copy')), findsOneWidget);
      notifier.value = ar;
      await tester.pumpAndSettle();
      expect(find.text(ar('copy')), findsOneWidget);
      expect(find.text(scripture), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.text(ar('copy')))),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;
  @override
  Future<ByteData> load(String key) async {
    final value = files[key];
    if (value == null) throw StateError('Missing asset');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }
}
