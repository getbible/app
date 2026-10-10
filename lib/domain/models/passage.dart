import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../../core/json.dart';

final class Passage {
  const Passage({
    required this.translation,
    required this.book,
    required this.chapter,
    this.verse,
  });

  factory Passage.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'passage');
    final int verseValue = optionalInt(json, 'verse');
    return Passage(
      translation: requireString(json, 'translation').toLowerCase(),
      book: requireInt(json, 'book'),
      chapter: requireInt(json, 'chapter'),
      verse: verseValue > 0 ? verseValue : null,
    ).validated();
  }

  final String translation;
  final int book;
  final int chapter;
  final int? verse;

  String get key => '$translation/$book/$chapter';
  String get canonicalKey => '$book/$chapter';

  Passage copyWith({
    String? translation,
    int? book,
    int? chapter,
    int? verse,
    bool clearVerse = false,
  }) => Passage(
    translation: translation ?? this.translation,
    book: book ?? this.book,
    chapter: chapter ?? this.chapter,
    verse: clearVerse ? null : verse ?? this.verse,
  );

  Passage validated() {
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(translation) ||
        book < 1 ||
        chapter < 0 ||
        (chapter == 0 && verse != null) ||
        (verse != null && verse! < 1)) {
      throw const FormatException('The passage reference is invalid.');
    }
    return this;
  }

  JsonMap toJson() => <String, Object?>{
    'modelVersion': 1,
    'translation': translation,
    'book': book,
    'chapter': chapter,
    if (verse != null) 'verse': verse,
  };

  @override
  bool operator ==(Object other) =>
      other is Passage &&
      other.translation == translation &&
      other.book == book &&
      other.chapter == chapter &&
      other.verse == verse;

  @override
  int get hashCode => Object.hash(translation, book, chapter, verse);
}

String bookSlug(String name) => unicode
    .nfc(name)
    .trim()
    .replaceAll(RegExp(r'[\s_/]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String normalizedBookSlug(String value) => bookSlug(
  value,
).toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

bool bookMatchesSlug(String name, String slug) =>
    normalizedBookSlug(name) == normalizedBookSlug(slug);

String canonicalPassagePath(Passage passage, String bookName) {
  final String verseSuffix = passage.verse == null
      ? ''
      : '?verse=${passage.verse}';
  return '/${Uri.encodeComponent(passage.translation.toUpperCase())}/${Uri.encodeComponent(bookSlug(bookName))}/${passage.chapter}$verseSuffix';
}

final class PassageLink {
  const PassageLink({
    required this.translation,
    required this.bookSlug,
    required this.chapter,
    this.verse,
  });

  final String translation;
  final String bookSlug;
  final int chapter;
  final int? verse;
}

PassageLink? parsePassageLink(Uri uri) {
  uri = readerLinkLocation(uri) ?? Uri(path: '/');
  if (uri.queryParametersAll['verse']?.length != null &&
      uri.queryParametersAll['verse']!.length != 1) {
    return null;
  }
  final List<String> parts = uri.pathSegments
      .where((String part) => part.isNotEmpty)
      .toList();
  if (parts.length != 3 && parts.length != 4) return null;
  final String translation = parts[0].toLowerCase();
  final int? chapter = int.tryParse(parts[2]);
  final String? pathVerse = parts.length == 4 ? parts[3] : null;
  final String? queryVerse = uri.queryParameters['verse'];
  if (pathVerse != null && queryVerse != null && pathVerse != queryVerse) {
    return null;
  }
  final String? verseSource = pathVerse ?? queryVerse;
  final int? verse = verseSource == null ? null : int.tryParse(verseSource);
  if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(translation) ||
      parts[1].isEmpty ||
      chapter == null ||
      chapter < 0 ||
      (verseSource != null && verse == null) ||
      (verse != null && (verse < 1 || chapter == 0))) {
    return null;
  }
  return PassageLink(
    translation: translation,
    // Uri.pathSegments already decoded exactly once. Decoding again changes
    // literal percent sequences in published names and may throw on valid URLs.
    bookSlug: parts[1],
    chapter: chapter,
    verse: verse,
  );
}

/// Normalize only supported public/native links; never reinterpret another
/// origin or an arbitrary URI scheme as a Scripture reference.
Uri? readerLinkLocation(Uri uri) {
  if (uri.toString().length > 4096) return null;
  if (uri.userInfo.isNotEmpty || uri.hasPort) return null;
  if (uri.scheme == 'getbible') {
    final path = uri.host.isEmpty ? uri.path : '/${uri.host}${uri.path}';
    return Uri(path: path, query: uri.hasQuery ? uri.query : null);
  }
  if (uri.hasScheme &&
      (uri.scheme != 'https' ||
          !const {'app.getbible.life', 'getbible.life'}.contains(uri.host))) {
    return null;
  }
  if (!uri.hasScheme && uri.hasAuthority) return null;
  // Accept links from older hash-based deployments as well as the current
  // friendly path router. The web host serves index.html for reader routes.
  if (uri.fragment.startsWith('/')) {
    return readerLinkLocation(Uri.parse(uri.fragment));
  }
  return Uri(path: uri.path, query: uri.hasQuery ? uri.query : null);
}

Uri shareablePassageUri(Passage passage, String bookName) => Uri.parse(
  'https://app.getbible.life${canonicalPassagePath(passage, bookName)}',
);
