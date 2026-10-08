import '../../core/json.dart';
import 'study_citation.dart';

/// The source's v2 reference resolution is retained, never relabelled as v3.
final class CommentaryReferenceProvenance {
  CommentaryReferenceProvenance({
    required this.api,
    required this.versification,
    required this.language,
    required this.names,
    required Iterable<String> translations,
    required Iterable<String> librarian,
    required Iterable<String> aliases,
  }) : translations = List<String>.unmodifiable(translations),
       librarian = List<String>.unmodifiable(librarian),
       aliases = List<String>.unmodifiable(aliases);

  final String api;
  final String versification;
  final String language;
  final String? names;
  final List<String> translations;
  final List<String> librarian;
  final List<String> aliases;
}

final class CommentaryMetadata {
  const CommentaryMetadata({
    required this.id,
    required this.name,
    required this.language,
    required this.version,
    required this.license,
    required this.sourceName,
    required this.sourceModuleUrl,
    required this.copyright,
    required this.about,
    required this.versification,
    required this.references,
    required this.source,
  });

  final String id;
  final String name;
  final String language;
  final String version;
  final String license;
  final String sourceName;
  final Uri sourceModuleUrl;
  final String copyright;
  final String about;
  final String versification;
  final CommentaryReferenceProvenance references;
  final JsonMap source;
}

/// Coverage is authoritative. A missing book or chapter is an ordinary empty
/// study result, not an invitation to download an unrelated resource.
final class CommentaryBookCoverage {
  CommentaryBookCoverage({
    required this.book,
    required this.name,
    required Iterable<int> chapters,
    required this.entryCount,
  }) : chapters = List<int>.unmodifiable(chapters);

  final int book;
  final String name;
  final List<int> chapters;
  final int entryCount;
}

final class CommentaryCoverage {
  CommentaryCoverage({
    required this.commentary,
    required this.language,
    required this.name,
    required Iterable<CommentaryBookCoverage> books,
    required this.source,
  }) : books = List<CommentaryBookCoverage>.unmodifiable(books);

  final String commentary;
  final String language;
  final String name;
  final List<CommentaryBookCoverage> books;
  final JsonMap source;

  bool covers(int book, int chapter) => books.any(
    (CommentaryBookCoverage coverage) =>
        coverage.book == book && coverage.chapters.contains(chapter),
  );
}

/// Chapter/verse zero denote source introductions, never Scripture verses.
final class CommentaryEntry {
  CommentaryEntry({
    required this.book,
    required this.chapter,
    required this.verse,
    required this.text,
    required Iterable<int> verses,
    required Iterable<StudyCitation> references,
    required this.source,
    this.osis,
  }) : verses = List<int>.unmodifiable(verses),
       references = List<StudyCitation>.unmodifiable(references);

  final int book;
  final int chapter;
  final int verse;
  final List<int> verses;
  final String? osis;
  final String text;
  final List<StudyCitation> references;
  final JsonMap source;

  bool get isIntroduction => chapter == 0 || verse == 0;
  bool coversVerse(int selectedVerse) => verses.isNotEmpty
      ? verses.contains(selectedVerse)
      : verse == selectedVerse;

  String get coverageLabel {
    if (chapter == 0) return 'Book introduction';
    if (verse == 0) return 'Chapter introduction';
    final List<int> covered = verses.isEmpty ? <int>[verse] : verses;
    return 'Chapter $chapter · ${covered.length == 1 ? 'verse' : 'verses'} ${covered.join(', ')}';
  }
}

final class CommentaryChapter {
  CommentaryChapter({
    required this.commentary,
    required this.language,
    required this.book,
    required this.name,
    required this.chapter,
    required Iterable<CommentaryEntry> entries,
    required this.source,
  }) : entries = List<CommentaryEntry>.unmodifiable(entries);

  final String commentary;
  final String language;
  final int book;
  final String name;
  final int chapter;
  final List<CommentaryEntry> entries;
  final JsonMap source;

  List<CommentaryEntry> entriesForVerse(int? verse) => verse == null
      ? entries
      : List<CommentaryEntry>.unmodifiable(
          entries.where((CommentaryEntry entry) => entry.coversVerse(verse)),
        );
}

/// Consecutive identical source quotations may span chapter boundaries. Display
/// their text once while retaining every ordered source entry, full coverage,
/// citation and OSIS. Distinct comments and nonconsecutive repeats stay separate.
final class CommentaryQuotation {
  CommentaryQuotation(Iterable<CommentaryEntry> entries)
    : entries = List<CommentaryEntry>.unmodifiable(entries);
  final List<CommentaryEntry> entries;
  String get text => entries.first.text;

  static List<CommentaryQuotation> group(Iterable<CommentaryEntry> entries) {
    final List<CommentaryQuotation> result = <CommentaryQuotation>[];
    final List<CommentaryEntry> pending = <CommentaryEntry>[];
    void flush() {
      if (pending.isEmpty) return;
      result.add(CommentaryQuotation(pending));
      pending.clear();
    }

    for (final CommentaryEntry entry in entries) {
      if (pending.isNotEmpty && pending.last.text != entry.text) flush();
      pending.add(entry);
    }
    flush();
    return List<CommentaryQuotation>.unmodifiable(result);
  }
}
