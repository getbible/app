import '../../core/json.dart';
import 'bible.dart';
import 'passage.dart';

/// One explicit chapter selection. Verse numbers are source identities, not
/// offsets into the API's verse array. The selected Bible owns book-name lookup.
final class ReferenceSelection {
  ReferenceSelection({
    required this.book,
    required this.chapter,
    required Iterable<int> verses,
  }) : verses = List<int>.unmodifiable(verses) {
    if (book < 1 ||
        chapter < 1 ||
        this.verses.isEmpty ||
        this.verses.any((int verse) => verse < 1)) {
      throw const FormatException(
        'A reference requires valid verse coordinates.',
      );
    }
  }

  factory ReferenceSelection.verse(Passage passage) {
    passage.validated();
    if (passage.verse == null) {
      throw const FormatException('Select a verse to preview its reference.');
    }
    return ReferenceSelection(
      book: passage.book,
      chapter: passage.chapter,
      verses: <int>[passage.verse!],
    );
  }

  final int book;
  final int chapter;
  final List<int> verses;
}

/// A citation's original label survives coordinate-based translation lookup.
sealed class ReferenceRequest {
  const ReferenceRequest({
    required this.translation,
    this.translationName,
    this.sourceLabel,
    this.translationDirection,
  });

  final String translation;
  final String? translationName;
  final String? sourceLabel;
  final String? translationDirection;
  String get label;
}

final class TextReferenceRequest extends ReferenceRequest {
  const TextReferenceRequest({
    required super.translation,
    required this.reference,
    super.translationName,
    super.sourceLabel,
    super.translationDirection,
  });

  final String reference;

  @override
  String get label => sourceLabel ?? reference;
}

final class StructuredReferenceRequest extends ReferenceRequest {
  StructuredReferenceRequest({
    required super.translation,
    required Iterable<ReferenceSelection> selections,
    super.translationName,
    super.sourceLabel,
    super.translationDirection,
  }) : selections = List<ReferenceSelection>.unmodifiable(selections);

  final List<ReferenceSelection> selections;

  @override
  String get label => sourceLabel ?? 'Selected Scripture';
}

/// Query v3 has a compact, chapter-keyed envelope. It is intentionally separate
/// from a static BibleChapter: full-chapter editorial context is not returned.
final class ReferenceChapter {
  ReferenceChapter({
    required this.key,
    required this.bookNumber,
    required this.chapter,
    required Iterable<Verse> verses,
    Iterable<String> references = const <String>[],
    this.bookName = '',
    this.direction = 'LTR',
    JsonMap metadata = const <String, Object?>{},
  }) : verses = List<Verse>.unmodifiable(verses),
       references = List<String>.unmodifiable(references),
       metadata = Map<String, Object?>.unmodifiable(metadata);

  factory ReferenceChapter.fromJson(
    String key,
    Object? value, {
    required String selectedTranslation,
  }) {
    final JsonMap json = requireJsonMap(value, 'reference chapter');
    for (final String field in <String>[
      'abbreviation',
      'book_name',
      'direction',
      'encoding',
      'lang',
      'language',
      'name',
      'translation',
    ]) {
      if (json.containsKey(field)) requireString(json, field);
    }
    final int book = requireInt(json, 'book_nr');
    final int chapter = requireInt(json, 'chapter');
    final String abbreviation = optionalString(json, 'abbreviation');
    if (book < 1 ||
        chapter < 1 ||
        key != '${selectedTranslation}_${book}_$chapter' ||
        (abbreviation.isNotEmpty &&
            abbreviation.toLowerCase() != selectedTranslation)) {
      throw const FormatException(
        'The reference response has an incompatible identity.',
      );
    }
    final List<Verse> verses =
        requireJsonList(json['verses'], 'reference verses')
            .map((Object? value) {
              final JsonMap verse = requireJsonMap(value, 'reference verse');
              requireString(verse, 'name');
              return Verse.fromJson(verse, fallbackChapter: chapter);
            })
            .toList(growable: false);
    if (verses.isEmpty ||
        verses.any(
          (Verse verse) => verse.chapter != chapter || verse.verse < 1,
        ) ||
        verses.map((Verse verse) => verse.verse).toSet().length !=
            verses.length) {
      throw const FormatException(
        'The reference response has invalid verse identities.',
      );
    }
    final List<String> refs = <String>[];
    if (json.containsKey('ref')) {
      for (final Object? ref in requireJsonList(
        json['ref'],
        'contributing references',
      )) {
        if (ref is! String) {
          throw const FormatException('A contributing reference must be text.');
        }
        refs.add(ref);
      }
    }
    return ReferenceChapter(
      key: key,
      bookNumber: book,
      chapter: chapter,
      verses: verses,
      references: refs,
      bookName: optionalString(json, 'book_name'),
      direction: optionalString(json, 'direction', 'LTR'),
      metadata: json,
    );
  }

  final String key;
  final int bookNumber;
  final int chapter;
  final String bookName;
  final String direction;
  final List<Verse> verses;
  final List<String> references;

  /// Includes all optional and additive API fields, including source metadata.
  final JsonMap metadata;

  bool get isRtl => direction.toUpperCase() == 'RTL';

  JsonMap toJson() => <String, Object?>{
    ...metadata,
    'book_nr': bookNumber,
    'chapter': chapter,
    'verses': verses
        .map((Verse verse) => verse.toJson())
        .toList(growable: false),
    if (references.isNotEmpty || metadata.containsKey('ref')) 'ref': references,
  };
}

final class ReferenceResult {
  ReferenceResult({
    required this.translation,
    required Iterable<ReferenceChapter> chapters,
    required Iterable<String> requestedReferences,
  }) : chapters = List<ReferenceChapter>.unmodifiable(chapters),
       requestedReferences = List<String>.unmodifiable(requestedReferences);

  factory ReferenceResult.fromJson(
    Object? value, {
    required String translation,
    required String reference,
  }) {
    final JsonMap json = requireJsonMap(value, 'Query response');
    if (json.isEmpty) {
      throw const FormatException('The requested reference is unavailable.');
    }
    return ReferenceResult(
      translation: translation,
      requestedReferences: <String>[reference],
      chapters: json.entries.map(
        (MapEntry<String, Object?> entry) => ReferenceChapter.fromJson(
          entry.key,
          entry.value,
          selectedTranslation: translation,
        ),
      ),
    );
  }

  final String translation;
  final List<ReferenceChapter> chapters;
  final List<String> requestedReferences;

  int get verseCount => chapters.fold<int>(
    0,
    (int count, ReferenceChapter chapter) => count + chapter.verses.length,
  );

  Passage passageFor(ReferenceChapter chapter, Verse verse) => Passage(
    translation: translation,
    book: chapter.bookNumber,
    chapter: chapter.chapter,
    verse: verse.verse,
  ).validated();

  String get copyText => chapters
      .map((ReferenceChapter chapter) {
        final String label = chapter.bookName.isNotEmpty
            ? '${chapter.bookName} ${chapter.chapter}'
            : chapter.references.isNotEmpty
            ? chapter.references.join('; ')
            : 'Book ${chapter.bookNumber}, chapter ${chapter.chapter}';
        return '$label (${translation.toUpperCase()})\n${chapter.verses.map((Verse verse) => '${verse.verse} ${verse.text}').join('\n')}';
      })
      .join('\n\n');
}

/// A structured request must resolve completely, even if the server returned
/// some other valid verses. It must never masquerade as successful partial data.
final class ReferenceLookupException implements Exception {
  const ReferenceLookupException(this.message);
  final String message;

  @override
  String toString() => message;
}
