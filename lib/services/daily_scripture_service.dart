import '../core/json.dart';
import '../domain/models/cache.dart';

/// Retains the feed's full selection in its opened chapter. Source text is not
/// used as Scripture: the reader obtains the selected verses from Bible v3.
DailyScriptureCache parseDailyScripture(Object? value, DateTime cachedAt) {
  final JsonMap json = requireJsonMap(value, 'daily Scripture');
  final String date = requireString(json, 'date');
  final String link = optionalString(
    json,
    json.containsKey('getbible')
        ? 'getbible'
        : json.containsKey('url')
        ? 'url'
        : 'link',
  );
  final String name = optionalString(
    json,
    json.containsKey('name') ? 'name' : 'reference',
  );
  final List<String> path =
      Uri.tryParse(link)?.pathSegments ?? const <String>[];
  final RegExpMatch? reference = RegExp(
    r'^(.+?)\s+(\d+)\s*:\s*(.+)',
  ).firstMatch(name);
  final String explicitBook = optionalString(json, 'book');
  final String bookName = explicitBook.isNotEmpty
      ? explicitBook
      : path.length >= 3
      ? path[1]
      : reference?.group(1) ?? '';
  final int chapter = _positive(
    json['chapter'] ??
        (path.length >= 3 ? path[2] : null) ??
        reference?.group(2),
  );
  final List<int> selected = <int>[
    ..._verseNumbers(json['verse'], chapter),
    ..._verseNumbers(json['verses'], chapter),
    ..._verseNumbers(path.length >= 4 ? path[3] : null, chapter),
    ..._verseNumbers(reference?.group(3), chapter),
  ];
  final Object? scripture = json['scripture'];
  if (scripture is List<Object?>) {
    for (final Object? row in scripture) {
      if (row is Map<String, Object?> &&
          _positive(row['chapter'] ?? row['chapter_nr'] ?? chapter) ==
              chapter) {
        selected.addAll(_verseNumbers(row['nr'], chapter));
      }
    }
  }
  if (bookName.isEmpty || chapter < 1 || selected.isEmpty) {
    throw const FormatException(
      'The daily Scripture response does not contain a complete reference.',
    );
  }
  return DailyScriptureCache(
    date: date,
    translation: 'kjv',
    bookName: bookName,
    chapter: chapter,
    verse: selected.first,
    verses: selected,
    cachedAt: cachedAt.toUtc(),
  );
}

int _positive(Object? value) {
  final String text = '$value';
  if (!RegExp(r'^\d+$').hasMatch(text)) return 0;
  return int.tryParse(text) ?? 0;
}

Iterable<int> _verseNumbers(Object? value, int chapter) sync* {
  if (value is List<Object?>) {
    for (final Object? item in value) {
      yield* _verseNumbers(item, chapter);
    }
    return;
  }
  if (value is! String && value is! int) return;
  final List<String> parts = '$value'
      .trim()
      .replaceAllMapped(RegExp(r'\s*([-–—:])\s*'), (match) => match[1]!)
      .split(RegExp(r'[,;\s]+'));
  int selectedChapter = chapter;
  for (final String part in parts) {
    final RegExpMatch? match = RegExp(
      r'^(?:(\d+):)?(\d+)(?:[-–—](\d+))?$',
    ).firstMatch(part);
    if (match == null) continue;
    if (match[1] != null) selectedChapter = _positive(match[1]);
    if (selectedChapter != chapter) continue;
    final int first = _positive(match[2]);
    final int last = _positive(match[3] ?? match[2]);
    if (first < 1 || last < first || last - first > 1000) continue;
    for (int verse = first; verse <= last; verse++) {
      yield verse;
    }
  }
}
