import '../core/json.dart';
import '../domain/models/cache.dart';

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
    r'^(.+?)\s+(\d+):(\d+)',
  ).firstMatch(name);
  final String explicitBook = optionalString(json, 'book');
  final String bookName = explicitBook.isNotEmpty
      ? explicitBook
      : path.length >= 3
      ? Uri.decodeComponent(path[path.length - 3])
      : reference?.group(1) ?? '';
  final int chapter = _positive(
    json['chapter'] ??
        (path.length >= 2 ? path[path.length - 2] : null) ??
        reference?.group(2),
  );
  final int verse = _positive(
    json['verse'] ??
        json['verses'] ??
        (path.isNotEmpty ? path.last : null) ??
        reference?.group(3) ??
        _firstVerse(json['scripture']),
  );
  if (bookName.isEmpty || chapter < 1 || verse < 1) {
    throw const FormatException(
      'The daily Scripture response does not contain a complete reference.',
    );
  }
  return DailyScriptureCache(
    date: date,
    translation: 'kjv',
    bookName: bookName,
    chapter: chapter,
    verse: verse,
    cachedAt: cachedAt.toUtc(),
  );
}

int _positive(Object? value) {
  final RegExpMatch? match = RegExp(r'\d+').firstMatch('$value');
  return match == null ? 0 : int.tryParse(match.group(0)!) ?? 0;
}

Object? _firstVerse(Object? value) {
  if (value is! List<Object?> || value.isEmpty) return null;
  final Object? first = value.first;
  return first is Map<String, Object?> ? first['nr'] : null;
}
