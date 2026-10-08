import '../../core/json.dart';
import 'passage.dart';

enum CacheFreshness { fresh, cachedVerified, cachedUnverified }

/// Serialized Scripture and HTTP caches cannot cross service/API boundaries.
final class ScriptureCacheIdentity {
  const ScriptureCacheIdentity({
    this.apiVersion = 'v3',
    this.schemaVersion = 2,
    this.sourceScope = '',
  });
  final String apiVersion;
  final int schemaVersion;
  final String sourceScope;
  String get prefix =>
      'bible:$apiVersion:s$schemaVersion:${sourceScope.isEmpty ? '' : 'origin:$sourceScope:'}';
  String key(String resource) => '$prefix$resource';
  static const ScriptureCacheIdentity legacy = ScriptureCacheIdentity(
    apiVersion: 'v2',
    schemaVersion: 1,
  );
}

final class RepositoryResult<T> {
  const RepositoryResult({
    required this.data,
    required this.freshness,
    required this.checkedAt,
    this.isLegacy = false,
    this.sourceApiVersion = 'v3',
    this.mayPersist = true,
  });

  final T data;
  final CacheFreshness freshness;
  final DateTime checkedAt;
  final bool isLegacy;
  final bool mayPersist;
  final String sourceApiVersion;

  bool get isCached => freshness != CacheFreshness.fresh;
  bool get isVerified => freshness != CacheFreshness.cachedUnverified;
}

final class DailyScriptureCache {
  const DailyScriptureCache({
    required this.date,
    required this.translation,
    required this.bookName,
    required this.chapter,
    required this.verse,
    required this.cachedAt,
  });

  factory DailyScriptureCache.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'daily Scripture');
    return DailyScriptureCache(
      date: requireString(json, 'date'),
      translation: optionalString(json, 'translation', 'kjv').toLowerCase(),
      bookName: requireString(json, 'bookName'),
      chapter: requireInt(json, 'chapter'),
      verse: requireInt(json, 'verse'),
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
        optionalInt(json, 'cachedAt', DateTime.now().millisecondsSinceEpoch),
        isUtc: true,
      ),
    );
  }

  final String date;
  final String translation;
  final String bookName;
  final int chapter;
  final int verse;
  final DateTime cachedAt;

  bool isCurrent(DateTime now) {
    final DateTime? parsed = DateTime.tryParse(date);
    if (parsed == null) {
      final RegExpMatch? match = RegExp(
        r'(\d{1,2})[- ]([A-Za-z]+)[- ,]+(\d{4})',
      ).firstMatch(date);
      if (match == null) return false;
      const List<String> months = <String>[
        'january',
        'february',
        'march',
        'april',
        'may',
        'june',
        'july',
        'august',
        'september',
        'october',
        'november',
        'december',
      ];
      final int month = months.indexWhere(
        (String value) => value.startsWith(match.group(2)!.toLowerCase()),
      );
      return month >= 0 &&
          int.parse(match.group(3)!) == now.year &&
          month + 1 == now.month &&
          int.parse(match.group(1)!) == now.day;
    }
    return parsed.year == now.year &&
        parsed.month == now.month &&
        parsed.day == now.day;
  }

  Passage toPassage(int bookNumber) => Passage(
    translation: translation,
    book: bookNumber,
    chapter: chapter,
    verse: verse,
  );

  JsonMap toJson() => <String, Object?>{
    'version': 1,
    'date': date,
    'translation': translation,
    'bookName': bookName,
    'chapter': chapter,
    'verse': verse,
    'cachedAt': cachedAt.millisecondsSinceEpoch,
  };
}
