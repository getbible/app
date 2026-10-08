import 'dart:convert';

import 'package:flutter/services.dart';

/// Positional locale reader shared with app.getbible.life/lib/i18n.ts.
final class UiStrings {
  const UiStrings(this.locale, this._messages);

  static const UiStrings english = UiStrings('en', <String>[]);
  static const Map<String, int> _indexes = <String, int>{
    'openBibleNavigation': 0,
    'openTodaysScripture': 2,
    'searchThisTranslation': 3,
    'search': 4,
    'previousChapter': 7,
    'nextChapter': 8,
    'openAsMarkdown': 10,
    'study': 11,
    'translation': 77,
    'book': 78,
    'chapter': 79,
    'readerOptions': 81,
    'textSize': 85,
    'readingFont': 86,
    'readingWidth': 87,
    'page': 88,
    'fullScreenWidth': 89,
    'verseLayout': 90,
    'oneVersePerLine': 91,
    'continuousParagraph': 92,
    'wordsOfEternalLife': 158,
    'lovinglyMaintainedBy': 159,
    'copy': 148,
    'downloadMarkdown': 149,
    'cancel': 176,
    'previous': 178,
    'next': 179,
  };
  static const Map<String, String> _english = <String, String>{
    'openBibleNavigation': 'Open Bible navigation',
    'openTodaysScripture': 'Open today\u2019s Scripture',
    'searchThisTranslation': 'Search this translation',
    'search': 'Search',
    'previousChapter': 'Previous chapter',
    'nextChapter': 'Next chapter',
    'openAsMarkdown': 'Open chapter as Markdown',
    'study': 'Study',
    'translation': 'Translation',
    'book': 'Book',
    'chapter': 'Chapter',
    'readerOptions': 'Reader options',
    'textSize': 'Text size',
    'readingFont': 'Reading font',
    'readingWidth': 'Reading width',
    'page': 'Page',
    'fullScreenWidth': 'Full screen width',
    'verseLayout': 'Verse layout',
    'oneVersePerLine': 'One verse per line',
    'continuousParagraph': 'Continuous paragraph',
    'wordsOfEternalLife': 'The words of eternal life',
    'lovinglyMaintainedBy': 'Lovingly maintained by',
    'copy': 'Copy',
    'downloadMarkdown': 'Download .md',
    'cancel': 'Cancel',
    'previous': 'Previous',
    'next': 'Next',
  };

  final String locale;
  final List<String> _messages;

  String call(String key, [Map<String, Object> variables = const {}]) {
    final int? index = _indexes[key];
    String value = index != null && index < _messages.length
        ? _messages[index]
        : '';
    if (value.isEmpty) value = _english[key] ?? key;
    for (final MapEntry<String, Object> item in variables.entries) {
      value = value.replaceAll('{${item.key}}', '${item.value}');
    }
    return value;
  }

  static Future<UiStrings> load(String? language) async {
    final String locale = normalizeLocale(language);
    if (locale == 'en') return english;
    try {
      final Object? decoded = jsonDecode(
        await rootBundle.loadString('assets/locales/$locale.json'),
      );
      if (decoded is List<Object?>) {
        return UiStrings(
          locale,
          decoded.map((Object? item) => item is String ? item : '').toList(),
        );
      }
    } on Object {
      // Missing or malformed packs deliberately fall back message-by-message.
    }
    return UiStrings(locale, const <String>[]);
  }

  static String normalizeLocale(String? language) {
    final String value = (language ?? 'en').trim().replaceAll('_', '-');
    if (value.isEmpty) return 'en';
    return switch (value.toLowerCase()) {
      'zh-cn' => 'zh-Hans',
      'zh-tw' => 'zh-Hant',
      _ => value,
    };
  }
}
