import '../../core/json.dart';
import '../../domain/models/commentary.dart';
import 'study_citation_adapter.dart';

/// Strict adapters for the published commentary v1 documents. Source text and
/// additive provenance survive unchanged; invalid identities never activate.
abstract final class CommentaryAdapter {
  static CommentaryMetadata metadata(Object? value, String module) {
    final JsonMap json = _schema(value, 'getbible-commentary-metadata-v1');
    _identity(json, 'id', module);
    final String language = _language(json);
    for (final String field in <String>[
      'module',
      'name',
      'versification',
      'conversion_note',
    ]) {
      _nonempty(json, field);
    }
    for (final String field in <String>[
      'version',
      'license',
      'driver',
      'source_type',
      'text_source',
      'copyright',
      'copyright_holder',
      'distribution_notes',
      'about',
    ]) {
      requireString(json, field);
    }
    for (final String field in <String>[
      'book_count',
      'chapter_count',
      'entry_count',
      'bytes',
    ]) {
      _integer(json, field, minimum: 0);
    }
    _constant(json, 'books_url', 'books.json');
    _constant(json, 'book_url_template', '{book}.json');
    _constant(json, 'chapter_url_template', '{book}/{chapter}.json');
    _constant(json, 'source', 'CrossWire SWORD');
    final Uri? sourceUrl = Uri.tryParse(_nonempty(json, 'source_module_url'));
    if (sourceUrl == null ||
        !<String>['http', 'https'].contains(sourceUrl.scheme) ||
        sourceUrl.host.isEmpty) {
      throw const FormatException('Invalid commentary source URL.');
    }
    final JsonMap storage = requireJsonMap(json['storage'], 'storage');
    for (final String field in <String>[
      'source_entry_count',
      'source_text_bytes',
      'text_bytes',
      'chapter_bytes',
      'book_bytes',
      'commentary_bytes',
      'published_bytes',
    ]) {
      _integer(storage, field, minimum: 0);
    }
    final Object? ratio = storage['repetition_ratio'];
    if (ratio is! num || !ratio.isFinite || ratio < 0) {
      throw const FormatException('Invalid commentary repetition ratio.');
    }
    final JsonMap contact = requireJsonMap(
      json['copyright_contact'],
      'contact',
    );
    for (final String field in <String>['name', 'email', 'address']) {
      requireString(contact, field);
    }
    final JsonMap refs = requireJsonMap(
      json['references'],
      'reference provenance',
    );
    _constant(refs, 'api', 'getbible-v2');
    final Object? names = refs['names'];
    if (!refs.containsKey('names') || (names != null && names is! String)) {
      throw const FormatException('Invalid commentary reference names.');
    }
    return CommentaryMetadata(
      id: module,
      name: requireString(json, 'name'),
      language: language,
      version: requireString(json, 'version'),
      license: requireString(json, 'license'),
      sourceName: requireString(json, 'source'),
      sourceModuleUrl: sourceUrl,
      copyright: requireString(json, 'copyright'),
      about: requireString(json, 'about'),
      versification: requireString(json, 'versification'),
      references: CommentaryReferenceProvenance(
        api: requireString(refs, 'api'),
        versification: requireString(refs, 'versification'),
        language: requireString(refs, 'language'),
        names: names as String?,
        translations: _strings(refs['translations']),
        librarian: _strings(refs['librarian']),
        aliases: _strings(refs['aliases']),
      ),
      source: _freezeMap(json),
    );
  }

  static CommentaryCoverage coverage(Object? value, String module) {
    final JsonMap json = _schema(value, 'getbible-commentary-books-v1');
    _identity(json, 'commentary', module);
    _constant(json, 'book_url_template', '{book}.json');
    _constant(json, 'chapter_url_template', '{book}/{chapter}.json');
    final List<CommentaryBookCoverage>
    books = requireJsonList(json['books'], 'books').map((Object? value) {
      final JsonMap book = requireJsonMap(value, 'commentary book coverage');
      final List<int> chapters = requireJsonList(book['chapters'], 'chapters')
          .map((Object? value) {
            return _integer(
              <String, Object?>{'chapter': value},
              'chapter',
              minimum: 0,
            );
          })
          .toList();
      if (chapters.toSet().length != chapters.length) {
        throw const FormatException('Duplicate commentary chapter coverage.');
      }
      return CommentaryBookCoverage(
        book: _integer(book, 'book', minimum: 1, maximum: 83),
        name: _nonempty(book, 'name'),
        chapters: chapters,
        entryCount: _integer(book, 'entry_count', minimum: 0),
      );
    }).toList();
    if (_integer(json, 'book_count', minimum: 0) != books.length ||
        books.map((CommentaryBookCoverage book) => book.book).toSet().length !=
            books.length) {
      throw const FormatException('Invalid commentary book coverage count.');
    }
    return CommentaryCoverage(
      commentary: module,
      language: _language(json),
      name: _nonempty(json, 'name'),
      books: books,
      source: _freezeMap(json),
    );
  }

  static CommentaryChapter chapter(
    Object? value,
    String module,
    int book,
    int chapter,
  ) {
    final JsonMap json = _schema(value, 'getbible-commentary-chapter-v1');
    _identity(json, 'commentary', module);
    if (_integer(json, 'book', minimum: 1, maximum: 83) != book ||
        _integer(json, 'chapter', minimum: 0) != chapter) {
      throw const FormatException('Commentary returned another chapter.');
    }
    final List<CommentaryEntry> entries =
        requireJsonList(json['entries'], 'entries').map((Object? value) {
          final JsonMap entry = requireJsonMap(value, 'commentary entry');
          if (_integer(entry, 'book', minimum: 1, maximum: 83) != book ||
              _integer(entry, 'chapter', minimum: 0) != chapter) {
            throw const FormatException(
              'Commentary entry has another chapter.',
            );
          }
          final int verse = _integer(entry, 'verse', minimum: 0);
          final List<int> verses = entry.containsKey('verses')
              ? requireJsonList(entry['verses'], 'covered verses')
                    .map(
                      (Object? value) => _integer(
                        <String, Object?>{'verse': value},
                        'verse',
                        minimum: 0,
                      ),
                    )
                    .toList()
              : <int>[];
          if (entry.containsKey('verses') &&
              (verses.length < 2 ||
                  verses.toSet().length != verses.length ||
                  !verses.contains(verse) ||
                  verses.any((int value) => value < verse))) {
            throw const FormatException('Invalid commentary verse range.');
          }
          final String? osis = entry.containsKey('osis')
              ? _nonempty(entry, 'osis')
              : null;
          return CommentaryEntry(
            book: book,
            chapter: chapter,
            verse: verse,
            verses: verses,
            osis: osis,
            text: requireString(entry, 'text'),
            references: entry.containsKey('references')
                ? requireJsonList(
                    entry['references'],
                    'references',
                  ).map(StudyCitationAdapter.parse)
                : const [],
            source: _freezeMap(entry),
          );
        }).toList();
    return CommentaryChapter(
      commentary: module,
      language: _language(json),
      book: book,
      name: _nonempty(json, 'name'),
      chapter: chapter,
      entries: entries,
      source: _freezeMap(json),
    );
  }
}

JsonMap _schema(Object? value, String schema) {
  final JsonMap json = requireJsonMap(value, schema);
  _constant(json, 'schema', schema);
  return json;
}

void _constant(JsonMap json, String field, String expected) {
  if (requireString(json, field) != expected) {
    throw FormatException('Unsupported commentary $field.');
  }
}

void _identity(JsonMap json, String field, String module) =>
    _constant(json, field, module);
String _nonempty(JsonMap json, String field) {
  final String value = requireString(json, field);
  if (value.isEmpty) throw FormatException('$field must not be empty.');
  return value;
}

String _language(JsonMap json) {
  final String value = requireString(json, 'language');
  if (value.length < 2) {
    throw const FormatException('Invalid commentary language.');
  }
  return value;
}

int _integer(JsonMap json, String field, {required int minimum, int? maximum}) {
  final int value = requireInt(json, field);
  if (value < minimum || (maximum != null && value > maximum)) {
    throw FormatException('Invalid commentary $field.');
  }
  return value;
}

List<String> _strings(Object? value) =>
    requireJsonList(value, 'source strings').map((Object? value) {
      if (value is! String || value.isEmpty) {
        throw const FormatException('Invalid source string.');
      }
      return value;
    }).toList();

JsonMap _freezeMap(JsonMap value) => Map<String, Object?>.unmodifiable(
  value.map((String key, Object? value) => MapEntry(key, _freeze(value))),
);
Object? _freeze(Object? value) {
  if (value is Map) return _freezeMap(requireJsonMap(value, 'source metadata'));
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
