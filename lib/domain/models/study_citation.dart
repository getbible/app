import 'reference.dart';
import 'study_context.dart';

/// A published study citation retains its original v2 coordinate provenance.
/// Coordinates are a request in the selected Bible, never a claim that the
/// source module and selected Bible share a versification.
final class StudyCitation {
  StudyCitation({
    required this.reference,
    required this.osis,
    required this.book,
    required this.chapter,
    this.verse,
    Iterable<int> verses = const <int>[],
    this.text,
  }) : verses = List<int>.unmodifiable(verses);

  final String reference;
  final String osis;
  final int book;
  final int chapter;
  final int? verse;
  final List<int> verses;
  final String? text;
  bool get isWholeChapter => verse == null && verses.isEmpty;
  bool get isScripture =>
      chapter > 0 &&
      (verse == null || verse! > 0) &&
      verses.every((int value) => value > 0);

  /// Verse selections use selected-Bible book discovery. Whole chapters retain
  /// the published citation, with truthful Query failure if its source-language
  /// spelling cannot be resolved in the selected Bible.
  ReferenceRequest requestFor(StudyContext context) {
    if (!isScripture) {
      throw const ReferenceLookupException(
        'Introduction citations are not Scripture verse selections.',
      );
    }
    // Public v2 study IDs beyond the common canon are not assumed to be the
    // same as Bible v3's dynamically published extended book identities.
    if (isWholeChapter || book > 66) {
      return TextReferenceRequest(
        translation: context.translation,
        translationName: context.translationName,
        translationDirection: context.direction,
        sourceLabel: reference,
        reference: reference,
      );
    }
    return StructuredReferenceRequest(
      translation: context.translation,
      translationName: context.translationName,
      translationDirection: context.direction,
      sourceLabel: reference,
      selections: <ReferenceSelection>[
        ReferenceSelection(
          book: book,
          chapter: chapter,
          verses: verses.isNotEmpty ? verses : <int>[verse!],
        ),
      ],
    );
  }
}
